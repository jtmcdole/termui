import 'package:flutter/foundation.dart' show ValueKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:fterm/src/audio/fterm_audio_controller.dart';
import 'package:fterm/src/commands/descriptor_adapters.dart';
import 'package:fterm/src/commands/fterm_capability_context.dart';
import 'package:fterm/src/commands/fterm_descriptor_models.dart';
import 'package:fterm/src/commands/shortcut_catalog.dart';
import 'package:fterm/src/launch_config.dart';
import 'package:fterm/src/settings_storage.dart';
import 'package:fterm/src/ui/palette/palette_models.dart';
import 'package:fterm/src/update/update_service.dart';
import 'package:fterm/src/workspace/fterm_workspace_controller.dart';
import 'package:fterm/src/workspace/local_host_driver.dart';
import 'package:material_ui/material_ui.dart' show Icons;
import 'package:termui_cast_client_core/termui_cast_client_core.dart'
    show CastClientRepository, DockPosition, WsClientTransport;
import 'package:termui_flutter/termui_flutter.dart'
    show DisabledShaderBackend, ShaderBackendKind, TerminalShaderController;

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

  const _StubLocalHostDriver({required this.isSupported});

  @override
  Future<LocalPaneHost> openShell(LocalShellConfig config) =>
      throw UnimplementedError();

  @override
  Future<void> dispose() async {}
}

final class _StubUpdateService implements UpdateService {
  @override
  final SelfUpdateCapability capability;

  const _StubUpdateService({required bool isSupportedDesktop})
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
  }) => throw UnimplementedError();

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
    shaderController: TerminalShaderController(
      backendFactory: (_) => const DisabledShaderBackend(),
    ),
    updateService: _StubUpdateService(isSupportedDesktop: supportsUpdates),
  );
}

void main() {
  const macDesktop = FtermCapabilityContext(
    isWeb: false,
    platform: .macOS,
    isDesktopHost: true,
    supportsUpdates: true,
  );
  const linuxDesktop = FtermCapabilityContext(
    isWeb: false,
    platform: .linux,
    isDesktopHost: true,
    supportsUpdates: true,
  );
  const windowsDesktop = FtermCapabilityContext(
    isWeb: false,
    platform: .windows,
    isDesktopHost: true,
    supportsUpdates: false,
  );
  const webLinux = FtermCapabilityContext(
    isWeb: true,
    platform: .linux,
    isDesktopHost: false,
    supportsUpdates: false,
  );
  const webMac = FtermCapabilityContext(
    isWeb: true,
    platform: .macOS,
    isDesktopHost: false,
    supportsUpdates: false,
  );

  group('projectDescriptorsToPaletteItems', () {
    test('projects actions with static and dynamic metadata, shortcuts, and '
        'async execute propagation', () async {
      final ws = _createWorkspace();
      addTearDown(ws.dispose);

      var stopped = false;
      var syncRuns = 0;
      var asyncRuns = 0;

      final descriptors = <FtermDescriptor>[
        FtermActionDescriptor(
          id: 'action.dynamic',
          category: 'Shader',
          title: 'Default Title',
          keywords: 'shader stop resume',
          icon: Icons.stop_circle_outlined,
          shortcut: FtermShortcuts.splitRight,
          dynamicTitleBuilder: (_) =>
              stopped ? 'Resume Shaders' : 'Emergency Stop Shaders',
          dynamicIconBuilder: (_) =>
              stopped ? Icons.play_arrow : Icons.stop_circle_outlined,
          subtitleBuilder: (_) => stopped ? 'Paused' : 'Running',
          activeBadgeBuilder: (_) => stopped ? 'Stopped' : null,
          execute: (_) async {
            await Future<void>.delayed(Duration.zero);
            stopped = !stopped;
            asyncRuns++;
          },
        ),
        FtermActionDescriptor(
          id: 'action.static',
          category: 'Workspace',
          title: 'Reload Shaders',
          keywords: 'reload refresh',
          icon: Icons.refresh,
          shortcut: FtermShortcuts.reloadShaders,
          execute: (_) => syncRuns++,
        ),
      ];

      final macItems = projectDescriptorsToPaletteItems(
        descriptors,
        ws,
        macDesktop,
      );
      expect(macItems, hasLength(2));
      expect(macItems[0].id, equals('action.dynamic'));
      expect(macItems[0].category, equals('Shader'));
      expect(macItems[0].title, equals('Emergency Stop Shaders'));
      expect(macItems[0].subtitle, equals('Running'));
      expect(macItems[0].activeBadge, isNull);
      expect(macItems[0].icon, equals(Icons.stop_circle_outlined));
      expect(macItems[0].shortcutHint, equals('Cmd+D'));
      expect(macItems[0].keywords, equals('shader stop resume'));
      expect(macItems[0].slider, isNull);

      expect(macItems[1].title, equals('Reload Shaders'));
      expect(macItems[1].shortcutHint, equals('Ctrl+Shift+F5'));
      expect(macItems[1].subtitle, isNull);
      expect(macItems[1].activeBadge, isNull);

      // Execute async and sync callbacks.
      await macItems[0].onExecute!();
      await macItems[1].onExecute!();
      expect(stopped, isTrue);
      expect(asyncRuns, equals(1));
      expect(syncRuns, equals(1));

      // Re-projecting reflects mutated workspace state and Web shortcut gating.
      final webItems = projectDescriptorsToPaletteItems(
        descriptors,
        ws,
        webMac,
      );
      expect(webItems[0].title, equals('Resume Shaders'));
      expect(webItems[0].subtitle, equals('Paused'));
      expect(webItems[0].activeBadge, equals('Stopped'));
      expect(webItems[0].icon, equals(Icons.play_arrow));
      expect(webItems[0].shortcutHint, equals(r'Ctrl+\ |'));
      // Desktop-only binding with no leader fallback suppresses hint on Web.
      expect(webItems[1].shortcutHint, isNull);

      expect(
        () => webItems.add(const PaletteItem(id: 'x', title: 'X')),
        throwsUnsupportedError,
      );
    });

    test('projects toggles with On/Off badge, activeIcon, Web shortcut gating, '
        'and live read-modify-write execution', () async {
      final ws = _createWorkspace();
      addTearDown(ws.dispose);

      var muted = false;
      var perfHud = true;

      final descriptors = <FtermDescriptor>[
        FtermToggleSettingDescriptor(
          id: 'system-audio-mute',
          paletteId: 'settings.toggle.mute_audio',
          section: .system,
          panelId: 'system-sound',
          panelTitle: 'Sound',
          controlKey: const ValueKey<String>('mute-toggle'),
          settingsLabel: 'Mute terminal bell',
          settingsCaption: 'Silence audio output',
          paletteCategory: 'Settings',
          paletteTitle: 'Toggle Mute Audio',
          keywords: 'sound mute audio',
          icon: Icons.volume_up,
          activeIcon: Icons.volume_off,
          read: (_) => muted,
          write: (_, next) async {
            await Future<void>.delayed(Duration.zero);
            muted = next;
          },
        ),
        FtermToggleSettingDescriptor(
          id: 'system-perf-hud',
          paletteId: 'settings.toggle.perf_hud',
          section: .system,
          panelId: 'system-graphics',
          panelTitle: 'Graphics',
          controlKey: const ValueKey<String>('perf-hud-toggle'),
          settingsLabel: 'Performance HUD',
          settingsCaption: 'Show FPS diagnostics',
          paletteCategory: 'Settings',
          paletteTitle: 'Toggle Performance HUD',
          keywords: 'perf hud fps',
          icon: Icons.speed,
          shortcut: FtermShortcuts.togglePerfHud,
          read: (_) => perfHud,
          write: (_, next) => perfHud = next,
        ),
      ];

      final desktopItems = projectDescriptorsToPaletteItems(
        descriptors,
        ws,
        linuxDesktop,
      );
      expect(desktopItems, hasLength(2));

      final muteOff = desktopItems[0];
      expect(muteOff.id, equals('settings.toggle.mute_audio'));
      expect(muteOff.category, equals('Settings'));
      expect(muteOff.title, equals('Toggle Mute Audio'));
      expect(muteOff.activeBadge, equals('Off'));
      expect(muteOff.icon, equals(Icons.volume_up));
      expect(muteOff.shortcutHint, isNull);

      final hudOn = desktopItems[1];
      expect(hudOn.id, equals('settings.toggle.perf_hud'));
      expect(hudOn.activeBadge, equals('On'));
      // Falls back to default icon when activeIcon is omitted.
      expect(hudOn.icon, equals(Icons.speed));
      expect(hudOn.shortcutHint, equals('Ctrl+Shift+F9'));

      // Live toggle execution: invoking twice flips false -> true -> false.
      await muteOff.onExecute!();
      expect(muted, isTrue);
      await muteOff.onExecute!();
      expect(muted, isFalse);

      // Re-project with muted == true to verify activeIcon and On badge.
      muted = true;
      final webItems = projectDescriptorsToPaletteItems(
        descriptors,
        ws,
        webLinux,
      );
      expect(webItems[0].activeBadge, equals('On'));
      expect(webItems[0].icon, equals(Icons.volume_off));
      expect(webItems[1].shortcutHint, isNull);
    });

    test('projects heterogeneous nullable and non-nullable enums via visitor '
        'and gates individual FtermEnumOption entries', () async {
      final ws = _createWorkspace();
      addTearDown(ws.dispose);

      int? maxFps;
      String? shellPreset = 'zsh';
      ShaderBackendKind? backendOverride;
      var dockPosition = DockPosition.left;

      final descriptors = <FtermDescriptor>[
        FtermEnumSettingDescriptor<int?>(
          id: 'shaders-max-fps',
          paletteIdPrefix: 'shader.max_fps',
          section: .shaders,
          panelId: 'shaders-playback',
          panelTitle: 'Playback',
          settingsLabel: 'Max Shader FPS',
          renderStyle: .segmented,
          paletteCategory: 'Shader',
          paletteTitlePrefix: 'Max FPS',
          keywords: 'shader fps',
          icon: Icons.speed,
          optionsBuilder: (_) => const <FtermEnumOption<int?>>[
            FtermEnumOption<int?>(
              idSuffix: 'uncapped',
              value: null,
              label: 'Uncapped',
              extraKeywords: 'unlimited',
            ),
            FtermEnumOption<int?>(idSuffix: '60', value: 60, label: '60 FPS'),
            FtermEnumOption<int?>(
              idSuffix: '240',
              value: 240,
              label: '240 FPS',
              featureFlag: 'flag.fps_240',
              extraKeywords: 'pro high-refresh',
            ),
            FtermEnumOption<int?>(
              idSuffix: 'win_only',
              value: 144,
              label: '144 FPS',
              visibility: .windowsDesktop,
            ),
          ],
          read: (_) => maxFps,
          write: (_, value) => maxFps = value,
        ),
        FtermEnumSettingDescriptor<String?>(
          id: 'shell-preset',
          paletteIdPrefix: 'shell.preset',
          section: .shell,
          panelId: 'shell-default',
          panelTitle: 'Default Shell',
          settingsLabel: 'Shell Preset',
          renderStyle: .segmented,
          paletteCategory: 'Shell',
          paletteTitlePrefix: 'Shell Preset',
          keywords: '  ',
          icon: Icons.terminal,
          optionsBuilder: (_) => <FtermEnumOption<String?>>[
            const FtermEnumOption<String?>(
              idSuffix: 'default',
              value: null,
              label: 'Default',
              extraKeywords: 'env-shell',
            ),
            FtermEnumOption<String?>(
              idSuffix: 'zsh',
              value: 'zsh',
              label: 'zsh',
              isAvailable: (ctx) => !ctx.isWindows,
            ),
          ],
          read: (_) => shellPreset,
          write: (_, value) => shellPreset = value,
        ),
        FtermEnumSettingDescriptor<ShaderBackendKind?>(
          id: 'shaders-backend',
          paletteIdPrefix: 'shader.backend',
          section: .shaders,
          panelId: 'shaders-pipeline',
          panelTitle: 'Pipeline',
          settingsLabel: 'Shader Backend',
          renderStyle: .segmented,
          paletteCategory: 'Shader',
          paletteTitlePrefix: 'Backend',
          keywords: 'gpu backend',
          icon: Icons.memory_outlined,
          optionsBuilder: (_) => const <FtermEnumOption<ShaderBackendKind?>>[
            FtermEnumOption<ShaderBackendKind?>(
              idSuffix: 'auto',
              value: null,
              label: 'Auto',
            ),
            FtermEnumOption<ShaderBackendKind?>(
              idSuffix: 'disabled',
              value: .disabled,
              label: 'Disabled',
            ),
          ],
          read: (_) => backendOverride,
          write: (_, value) async {
            await Future<void>.delayed(Duration.zero);
            backendOverride = value;
          },
        ),
        FtermEnumSettingDescriptor<DockPosition>(
          id: 'interface-dock-position',
          paletteIdPrefix: 'interface.dock',
          section: .interface,
          panelId: 'interface-tab-bar',
          panelTitle: 'Tab Bar',
          settingsLabel: 'Tab Bar Position',
          renderStyle: .segmented,
          paletteCategory: 'Interface',
          paletteTitlePrefix: 'Dock Position',
          keywords: 'dock tabs',
          icon: Icons.view_quilt_outlined,
          optionsBuilder: (_) => const <FtermEnumOption<DockPosition>>[
            FtermEnumOption<DockPosition>(
              idSuffix: 'top',
              value: .top,
              label: 'Top',
            ),
            FtermEnumOption<DockPosition>(
              idSuffix: 'left',
              value: .left,
              label: 'Left',
            ),
          ],
          read: (_) => dockPosition,
          write: (_, value) => dockPosition = value,
        ),
      ];

      final linuxItems = projectDescriptorsToPaletteItems(
        descriptors,
        ws,
        linuxDesktop,
      );
      final byId = <String, PaletteItem>{
        for (final item in linuxItems) item.id: item,
      };

      // Flagged-off and Windows-only options never leak on plain Linux desktop.
      expect(byId.containsKey('shader.max_fps.240'), isFalse);
      expect(byId.containsKey('shader.max_fps.win_only'), isFalse);
      expect(
        byId.keys.toList(),
        equals(const <String>[
          'shader.max_fps.uncapped',
          'shader.max_fps.60',
          'shell.preset.default',
          'shell.preset.zsh',
          'shader.backend.auto',
          'shader.backend.disabled',
          'interface.dock.top',
          'interface.dock.left',
        ]),
      );

      // Nullable equality, titles, and clean keyword joining.
      expect(
        byId['shader.max_fps.uncapped']!.title,
        equals('Max FPS: Uncapped'),
      );
      expect(byId['shader.max_fps.uncapped']!.activeBadge, equals('Active'));
      expect(
        byId['shader.max_fps.uncapped']!.keywords,
        equals('shader fps unlimited'),
      );
      expect(byId['shader.max_fps.60']!.activeBadge, isNull);
      expect(byId['shader.max_fps.60']!.keywords, equals('shader fps'));

      expect(byId['shell.preset.default']!.keywords, equals('env-shell'));
      expect(byId['shell.preset.default']!.activeBadge, isNull);
      expect(byId['shell.preset.zsh']!.keywords, isEmpty);
      expect(byId['shell.preset.zsh']!.activeBadge, equals('Active'));

      expect(byId['shader.backend.auto']!.activeBadge, equals('Active'));
      expect(byId['shader.backend.disabled']!.activeBadge, isNull);

      expect(byId['interface.dock.top']!.activeBadge, isNull);
      expect(byId['interface.dock.left']!.activeBadge, equals('Active'));

      // Execute writes across nullable & non-nullable T without TypeError.
      await byId['shader.max_fps.60']!.onExecute!();
      expect(maxFps, equals(60));
      await byId['shell.preset.default']!.onExecute!();
      expect(shellPreset, isNull);
      await byId['shader.backend.disabled']!.onExecute!();
      expect(backendOverride, equals(ShaderBackendKind.disabled));
      await byId['interface.dock.top']!.onExecute!();
      expect(dockPosition, equals(DockPosition.top));

      // Enabling feature flag + Windows platform surfaces gated options and
      // hides option failing isAvailable.
      const windowsFlagged = FtermCapabilityContext(
        isWeb: false,
        platform: .windows,
        isDesktopHost: true,
        supportsUpdates: false,
        enabledFeatures: <String>{'flag.fps_240'},
      );
      final windowsItems = projectDescriptorsToPaletteItems(
        descriptors,
        ws,
        windowsFlagged,
      );
      final winIds = <String>[for (final item in windowsItems) item.id];
      expect(winIds, contains('shader.max_fps.240'));
      expect(winIds, contains('shader.max_fps.win_only'));
      expect(winIds, isNot(contains('shell.preset.zsh')));
    });

    test('emits zero items when all enum options are gated off', () {
      final ws = _createWorkspace();
      addTearDown(ws.dispose);

      var readCalls = 0;
      final descriptor = FtermEnumSettingDescriptor<String>(
        id: 'enum-all-hidden',
        paletteIdPrefix: 'test.hidden_enum',
        section: .system,
        panelId: 'p',
        panelTitle: 'P',
        settingsLabel: 'Hidden Options',
        renderStyle: .dropdown,
        paletteCategory: 'System',
        paletteTitlePrefix: 'Hidden',
        icon: Icons.tune,
        optionsBuilder: (_) => const <FtermEnumOption<String>>[
          FtermEnumOption<String>(
            idSuffix: 'secret',
            value: 'secret',
            label: 'Secret',
            featureFlag: 'flag.secret',
          ),
        ],
        read: (_) {
          readCalls++;
          return 'secret';
        },
        write: (_, _) {},
      );

      final items = projectDescriptorsToPaletteItems(
        <FtermDescriptor>[descriptor],
        ws,
        linuxDesktop,
      );
      expect(items, isEmpty);
      expect(readCalls, equals(0));
    });

    test('projects sliders with clamping, formatting, divisions, and '
        'usesCustomSettingsWidget inclusion', () {
      final ws = _createWorkspace();
      addTearDown(ws.dispose);

      var opacity = 1.8;
      var fontSize = double.nan;

      final descriptors = <FtermDescriptor>[
        FtermSliderSettingDescriptor(
          id: 'themes-bg-opacity',
          paletteId: 'appearance.background_opacity',
          section: .themes,
          panelId: 'themes-background',
          panelTitle: 'Background',
          label: 'Background Opacity',
          paletteCategory: 'Appearance',
          keywords: 'opacity alpha',
          icon: Icons.opacity,
          min: 0.0,
          max: 1.0,
          step: 0.05,
          formatValue: (v) => '${(v.clamp(0.0, 1.0) * 100).round()}%',
          read: (_) => opacity,
          write: (_, value) => opacity = value,
        ),
        FtermSliderSettingDescriptor(
          id: 'themes-font-size',
          paletteId: 'appearance.font_size',
          section: .themes,
          panelId: 'themes-typography',
          panelTitle: 'Typography',
          label: 'Font Size',
          paletteCategory: 'Appearance',
          keywords: 'font size pt',
          icon: Icons.format_size,
          min: 8.0,
          max: 32.0,
          step: 1.0,
          divisions: 24,
          usesCustomSettingsWidget: true,
          formatValue: (v) => '${v.round()} pt',
          read: (_) => fontSize,
          write: (_, value) => fontSize = value,
        ),
      ];

      final items = projectDescriptorsToPaletteItems(
        descriptors,
        ws,
        linuxDesktop,
      );
      expect(items, hasLength(2));

      final opacityItem = items[0];
      expect(opacityItem.id, equals('appearance.background_opacity'));
      expect(opacityItem.category, equals('Appearance'));
      expect(opacityItem.title, equals('Background Opacity'));
      expect(opacityItem.onExecute, isNull);
      final opacitySpec = opacityItem.slider!;
      expect(opacitySpec.value, equals(1.0));
      expect(opacitySpec.min, equals(0.0));
      expect(opacitySpec.max, equals(1.0));
      expect(opacitySpec.step, equals(0.05));
      expect(opacitySpec.divisions, isNull);
      expect(opacitySpec.formatValue(0.85), equals('85%'));

      // onChanged clamps below min, above max, and preserves in-range values.
      opacitySpec.onChanged(-0.4);
      expect(opacity, equals(0.0));
      opacitySpec.onChanged(2.5);
      expect(opacity, equals(1.0));
      opacitySpec.onChanged(0.65);
      expect(opacity, equals(0.65));

      // Custom-widget slider still projects to Palette and guards NaN -> min.
      final fontItem = items[1];
      expect(fontItem.id, equals('appearance.font_size'));
      final fontSpec = fontItem.slider!;
      expect(fontSpec.value, equals(8.0));
      expect(fontSpec.divisions, equals(24));
      expect(fontSpec.formatValue(14.0), equals('14 pt'));
      fontSpec.onChanged(double.nan);
      expect(fontSize, equals(8.0));
      fontSpec.onChanged(16.0);
      expect(fontSize, equals(16.0));
    });

    test('omits custom settings and filters descriptors by visibility, '
        'featureFlag, and isAvailable', () {
      final ws = _createWorkspace();
      addTearDown(ws.dispose);

      final descriptors = <FtermDescriptor>[
        const FtermCustomSettingDescriptor(
          id: 'shell-executable',
          section: .shell,
          panelId: 'shell-default',
          panelTitle: 'Default Shell',
          title: 'Shell Executable',
          paletteExcludedReason: 'Free-form text field in Settings only.',
        ),
        FtermActionDescriptor(
          id: 'action.desktop_only',
          category: 'Diagnostics',
          title: 'Toggle Trace Recording',
          icon: Icons.fiber_manual_record,
          visibility: .desktopOnly,
          execute: (_) {},
        ),
        FtermActionDescriptor(
          id: 'action.flagged',
          category: 'Experimental',
          title: 'Experimental Action',
          icon: Icons.science_outlined,
          featureFlag: 'flag.experimental',
          execute: (_) {},
        ),
        FtermActionDescriptor(
          id: 'action.predicate',
          category: 'Updates',
          title: 'Update Action',
          icon: Icons.system_update_alt,
          isAvailable: (ctx) => ctx.supportsUpdates,
          execute: (_) {},
        ),
      ];

      expect(
        projectDescriptorsToPaletteItems(descriptors, ws, webLinux),
        isEmpty,
      );

      final plainLinuxIds = <String>[
        for (final item in projectDescriptorsToPaletteItems(
          descriptors,
          ws,
          linuxDesktop,
        ))
          item.id,
      ];
      expect(
        plainLinuxIds,
        equals(const <String>['action.desktop_only', 'action.predicate']),
      );

      final windowsIds = <String>[
        for (final item in projectDescriptorsToPaletteItems(
          descriptors,
          ws,
          windowsDesktop,
        ))
          item.id,
      ];
      expect(windowsIds, equals(const <String>['action.desktop_only']));

      const flaggedLinux = FtermCapabilityContext(
        isWeb: false,
        platform: .linux,
        isDesktopHost: true,
        supportsUpdates: true,
        enabledFeatures: <String>{'flag.experimental'},
      );
      final flaggedIds = <String>[
        for (final item in projectDescriptorsToPaletteItems(
          descriptors,
          ws,
          flaggedLinux,
        ))
          item.id,
      ];
      expect(
        flaggedIds,
        equals(const <String>[
          'action.desktop_only',
          'action.flagged',
          'action.predicate',
        ]),
      );
    });
  });

  group('projectDescriptorsToSettingsSearchEntries', () {
    test('skips actions and projects all four setting subtypes with '
        'searchTitle override and metadata propagation', () {
      bool availabilityPredicate(FtermCapabilityContext ctx) =>
          ctx.isDesktopHost;

      final descriptors = <FtermDescriptor>[
        FtermActionDescriptor(
          id: 'action.skip_me',
          category: 'Workspace',
          title: 'Should Be Skipped',
          icon: Icons.bolt,
          execute: (_) {},
        ),
        FtermToggleSettingDescriptor(
          id: 'system-perf-hud',
          paletteId: 'settings.toggle.perf_hud',
          section: .system,
          panelId: 'system-graphics',
          panelTitle: 'Graphics & Performance',
          controlKey: const ValueKey<String>('perf-hud'),
          settingsLabel: 'Performance HUD',
          settingsCaption: 'FPS overlay',
          searchTitle: 'Performance HUD (FPS • Ctrl+Shift+F9)',
          paletteCategory: 'Settings',
          paletteTitle: 'Toggle Performance HUD',
          keywords: 'perf hud fps',
          icon: Icons.speed,
          featureFlag: 'flag.perf_hud',
          isAvailable: availabilityPredicate,
          read: (_) => false,
          write: (_, _) {},
        ),
        FtermToggleSettingDescriptor(
          id: 'interface-copy-on-select',
          paletteId: 'settings.toggle.copy_on_select',
          section: .interface,
          panelId: 'interface-clipboard',
          panelTitle: 'Clipboard & Selection',
          controlKey: const ValueKey<String>('copy-select'),
          settingsLabel: 'Copy on mouse selection',
          settingsCaption: 'Copy selection',
          paletteCategory: 'Settings',
          paletteTitle: 'Toggle Copy on Selection',
          keywords: 'clipboard copy',
          icon: Icons.content_copy,
          read: (_) => false,
          write: (_, _) {},
        ),
        FtermEnumSettingDescriptor<int?>(
          id: 'shaders-max-fps',
          paletteIdPrefix: 'shader.max_fps',
          section: .shaders,
          panelId: 'shaders-playback',
          panelTitle: 'Playback & Frame Pacing',
          settingsLabel: 'Max FPS',
          searchTitle: 'Max Shader FPS',
          renderStyle: .segmented,
          paletteCategory: 'Shader',
          paletteTitlePrefix: 'Max FPS',
          keywords: 'fps cap',
          icon: Icons.speed,
          optionsBuilder: (_) => const <FtermEnumOption<int?>>[],
          read: (_) => null,
          write: (_, _) {},
        ),
        FtermEnumSettingDescriptor<DockPosition>(
          id: 'interface-dock-position',
          paletteIdPrefix: 'interface.dock',
          section: .interface,
          panelId: 'interface-tab-bar',
          panelTitle: 'Tab Bar',
          settingsLabel: 'Tab Bar Position',
          renderStyle: .segmented,
          paletteCategory: 'Interface',
          paletteTitlePrefix: 'Dock Position',
          keywords: 'dock top left hidden',
          icon: Icons.view_quilt_outlined,
          optionsBuilder: (_) => const <FtermEnumOption<DockPosition>>[],
          read: (_) => .top,
          write: (_, _) {},
        ),
        FtermSliderSettingDescriptor(
          id: 'themes-bg-opacity',
          paletteId: 'appearance.background_opacity',
          section: .themes,
          panelId: 'themes-background',
          panelTitle: 'Background',
          label: 'Opacity',
          searchTitle: 'Background Opacity',
          paletteCategory: 'Appearance',
          keywords: 'alpha glass',
          icon: Icons.opacity,
          min: 0.0,
          max: 1.0,
          step: 0.05,
          formatValue: (v) => '$v',
          read: (_) => 1.0,
          write: (_, _) {},
        ),
        FtermSliderSettingDescriptor(
          id: 'themes-font-size',
          paletteId: 'appearance.font_size',
          section: .themes,
          panelId: 'themes-typography',
          panelTitle: 'Typography',
          label: 'Font Size',
          paletteCategory: 'Appearance',
          keywords: 'font pt',
          icon: Icons.format_size,
          min: 8.0,
          max: 32.0,
          step: 1.0,
          usesCustomSettingsWidget: true,
          formatValue: (v) => '$v',
          read: (_) => 14.0,
          write: (_, _) {},
        ),
        const FtermCustomSettingDescriptor(
          id: 'automation-port',
          section: .automation,
          panelId: 'automation-network',
          panelTitle: 'Network & Authentication',
          title: 'Loopback Port',
          keywords: 'port localhost tcp',
          visibility: .desktopOnly,
          featureFlag: 'flag.automation',
        ),
      ];

      final entries = projectDescriptorsToSettingsSearchEntries(descriptors);
      expect(entries, hasLength(7));
      expect(
        <String>[for (final entry in entries) entry.id],
        equals(const <String>[
          'system-perf-hud',
          'interface-copy-on-select',
          'shaders-max-fps',
          'interface-dock-position',
          'themes-bg-opacity',
          'themes-font-size',
          'automation-port',
        ]),
      );

      // Toggle with searchTitle override, featureFlag, and isAvailable.
      final perfEntry = entries[0];
      expect(perfEntry.section, equals(FtermSettingsSection.system));
      expect(perfEntry.panelId, equals('system-graphics'));
      expect(perfEntry.panelTitle, equals('Graphics & Performance'));
      expect(perfEntry.title, equals('Performance HUD (FPS • Ctrl+Shift+F9)'));
      expect(perfEntry.keywords, equals('perf hud fps'));
      expect(perfEntry.desktopOnly, isFalse);
      expect(perfEntry.windowsOnly, isFalse);
      expect(perfEntry.featureFlag, equals('flag.perf_hud'));
      expect(perfEntry.isAvailable, same(availabilityPredicate));

      // Toggle without searchTitle falls back to settingsLabel.
      expect(entries[1].title, equals('Copy on mouse selection'));

      // Enum with and without searchTitle override.
      expect(entries[2].title, equals('Max Shader FPS'));
      expect(entries[3].title, equals('Tab Bar Position'));

      // Slider with and without searchTitle override.
      expect(entries[4].title, equals('Background Opacity'));
      expect(entries[5].title, equals('Font Size'));

      // Custom setting entry.
      final portEntry = entries[6];
      expect(portEntry.section, equals(FtermSettingsSection.automation));
      expect(portEntry.title, equals('Loopback Port'));
      expect(portEntry.desktopOnly, isTrue);
      expect(portEntry.windowsOnly, isFalse);
      expect(portEntry.featureFlag, equals('flag.automation'));

      expect(() => entries.add(portEntry), throwsUnsupportedError);
    });

    test('maps every FtermVisibility value accurately to desktopOnly and '
        'windowsOnly flags', () {
      final descriptors = <FtermDescriptor>[
        for (final visibility in FtermVisibility.values)
          FtermCustomSettingDescriptor(
            id: 'vis-${visibility.name}',
            section: .system,
            panelId: 'system-vis',
            panelTitle: 'Visibility',
            title: 'Setting ${visibility.name}',
            visibility: visibility,
          ),
      ];

      final entries = projectDescriptorsToSettingsSearchEntries(descriptors);
      final byId = <String, SettingsSearchEntry>{
        for (final entry in entries) entry.id: entry,
      };

      for (final visibility in FtermVisibility.values) {
        final entry = byId['vis-${visibility.name}']!;
        expect(
          entry.desktopOnly,
          equals(visibility != FtermVisibility.always),
          reason: 'desktopOnly mismatch for $visibility',
        );
        expect(
          entry.windowsOnly,
          equals(visibility == FtermVisibility.windowsDesktop),
          reason: 'windowsOnly mismatch for $visibility',
        );
      }
    });
  });
}
