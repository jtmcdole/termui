import 'package:flutter_test/flutter_test.dart';
import 'package:fterm/src/audio/fterm_audio_controller.dart';
import 'package:fterm/src/automation/automation_models.dart';
import 'package:fterm/src/commands/fterm_capability_context.dart';
import 'package:fterm/src/commands/fterm_descriptor_models.dart';
import 'package:fterm/src/commands/settings_descriptors.dart';
import 'package:fterm/src/commands/shortcut_catalog.dart';
import 'package:fterm/src/launch_config.dart';
import 'package:fterm/src/settings_storage.dart';
import 'package:fterm/src/ui/fterm_overlays.dart';
import 'package:fterm/src/ui/settings/settings_catalog.dart';
import 'package:fterm/src/ui/settings/settings_descriptor_renderer.dart';
import 'package:fterm/src/ui/settings/settings_primitives.dart';
import 'package:fterm/src/update/update_service.dart';
import 'package:fterm/src/workspace/fterm_workspace_controller.dart';
import 'package:fterm/src/workspace/local_host_driver.dart';
import 'package:material_ui/material_ui.dart';
import 'package:termui/termui.dart' as tui;
import 'package:termui_cast_client_core/termui_cast_client_core.dart'
    show CastClientRepository, WsClientTransport;
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

final class _FakeAutomationBackend implements AutomationHttpServerBackend {
  @override
  bool get isSupported => true;

  bool _isRunning = false;
  int? _boundPort;

  _FakeAutomationBackend();

  @override
  bool get isRunning => _isRunning;

  @override
  int? get boundPort => _boundPort;

  @override
  Future<void> start({
    required int port,
    required String password,
    required bool allowPty,
    required AutomationRequestHandler onRequest,
  }) async {
    _isRunning = true;
    _boundPort = port;
  }

  @override
  Future<void> stop() async {
    _isRunning = false;
    _boundPort = null;
  }

  @override
  void updatePassword(String password) {}

  @override
  void updateAllowPty(bool allowPty) {}
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
  AutomationHttpServerBackend? automationBackend,
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
    automationServerBackend: automationBackend ?? _FakeAutomationBackend(),
  );
}

final class _EnumRoundTripVisitor
    implements FtermEnumDescriptorVisitor<Future<void>> {
  final FtermWorkspaceController workspace;
  final FtermCapabilityContext capabilities;

  const _EnumRoundTripVisitor({
    required this.workspace,
    required this.capabilities,
  });

  @override
  Future<void> visitEnum<T>(FtermEnumSettingDescriptor<T> descriptor) async {
    final options = <FtermEnumOption<T>>[
      for (final option in descriptor.optionsBuilder(capabilities))
        if (option.isVisibleFor(capabilities)) option,
    ];
    expect(
      options,
      isNotEmpty,
      reason: 'No visible options for ${descriptor.id}',
    );

    for (final option in options) {
      await descriptor.write(workspace, option.value);
      expect(
        descriptor.read(workspace),
        equals(option.value),
        reason:
            'Enum ${descriptor.id} failed round-trip for suffix '
            '"${option.idSuffix}"',
      );
    }
  }
}

final class _EnumOptionInspector
    implements
        FtermEnumDescriptorVisitor<
          ({List<String> suffixes, List<Key?> keys, bool isDropdown})
        > {
  final FtermCapabilityContext capabilities;

  const _EnumOptionInspector(this.capabilities);

  @override
  ({List<String> suffixes, List<Key?> keys, bool isDropdown}) visitEnum<T>(
    FtermEnumSettingDescriptor<T> descriptor,
  ) {
    final visible = <FtermEnumOption<T>>[
      for (final option in descriptor.optionsBuilder(capabilities))
        if (option.isVisibleFor(capabilities)) option,
    ];
    return (
      suffixes: <String>[for (final option in visible) option.idSuffix],
      keys: <Key?>[for (final option in visible) option.settingsKey],
      isDropdown: descriptor.renderStyle == .dropdown,
    );
  }
}

Widget _wrapForWidgetTest(Widget child) => MaterialApp(
  home: Scaffold(
    body: SizedBox(width: 600, child: SingleChildScrollView(child: child)),
  ),
);

void main() {
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
    supportsUpdates: true,
  );
  const macDesktop = FtermCapabilityContext(
    isWeb: false,
    platform: .macOS,
    isDesktopHost: true,
    supportsUpdates: true,
  );
  const webLinux = FtermCapabilityContext(
    isWeb: true,
    platform: .linux,
    isDesktopHost: false,
    supportsUpdates: false,
  );

  final palette = FtermOverlayPalette.fromTerminalTheme(
    tui.TerminalColorTheme.presets.first,
  );

  group('allSettingDescriptors catalog invariants', () {
    test('has unique IDs matching SettingsCatalog.allSearchItems 1:1', () {
      final descriptorIds = <String>[
        for (final descriptor in allSettingDescriptors) descriptor.id,
      ];
      final catalogIds = <String>[
        for (final item in SettingsCatalog.allSearchItems) item.id,
      ];

      expect(descriptorIds.toSet().length, equals(descriptorIds.length));
      expect(descriptorIds, equals(catalogIds));

      for (final descriptor in allSettingDescriptors) {
        expect(settingDescriptorById(descriptor.id), same(descriptor));
      }
      expect(settingDescriptorById('does-not-exist'), isNull);
    });

    test('partitions cleanly across every FtermSettingsSection', () {
      final combined = <String>[];
      for (final section in FtermSettingsSection.values) {
        final items = settingDescriptorsForSection(section);
        expect(items, isNotEmpty, reason: 'Section $section must have items');
        for (final item in items) {
          combined.add(item.id);
        }
      }
      expect(
        combined,
        equals(<String>[for (final d in allSettingDescriptors) d.id]),
      );
    });

    test('palette group lists cover every non-custom setting exactly once', () {
      final paletteGroups = <FtermDescriptor>[
        ...appearanceSettingDescriptors,
        ...shaderControlSettingDescriptors,
        ...cliShaderSettingDescriptors,
        ...paletteSettingsToggleDescriptors,
        ...paletteSettingsEnumDescriptors,
      ];
      final nonCustom = <FtermDescriptor>[
        for (final d in allSettingDescriptors)
          if (d is! FtermCustomSettingDescriptor) d,
      ];

      final groupIds = <String>[for (final d in paletteGroups) d.id];
      expect(groupIds.toSet().length, equals(groupIds.length));
      expect(
        groupIds.toSet(),
        equals(<String>{for (final d in nonCustom) d.id}),
      );
    });

    test('preserves critical palette IDs, suffixes, keys, and shortcuts', () {
      final maxFps =
          settingDescriptorById('shaders-max-fps')!
              as FtermEnumSettingDescriptor<int?>;
      final maxFpsOptions = maxFps.optionsBuilder(linuxDesktop);
      expect(maxFpsOptions.first.value, isNull);
      expect(maxFpsOptions.first.idSuffix, equals('uncapped'));
      expect(
        maxFpsOptions.first.settingsKey,
        equals(const ValueKey('settings-max-shader-fps-auto')),
      );

      final cliStacking =
          settingDescriptorById('shaders-cli-stacking')!
              as FtermEnumSettingDescriptor<CliFullPaneShaderMode>;
      final stackingOptions = cliStacking.optionsBuilder(linuxDesktop);
      expect(<String>[
        for (final o in stackingOptions) o.idSuffix,
      ], equals(<String>['cliBeforeUser', 'cliReplacesUser', 'askOnConflict']));
      expect(
        <Key?>[for (final o in stackingOptions) o.settingsKey],
        equals(<Key?>[
          const ValueKey('settings-cli-full-pane-mode-cli_before_user'),
          const ValueKey('settings-cli-full-pane-mode-cli_replaces_user'),
          const ValueKey('settings-cli-full-pane-mode-ask_on_conflict'),
        ]),
      );

      final fontSize =
          settingDescriptorById('themes-font-size')!
              as FtermSliderSettingDescriptor;
      expect(fontSize.usesCustomSettingsWidget, isTrue);
      expect(fontSize.sliderKey, isNull);
      expect(fontSize.valueKey, isNull);

      final perfHud =
          settingDescriptorById('system-perf-hud')!
              as FtermToggleSettingDescriptor;
      expect(perfHud.shortcut, same(FtermShortcuts.togglePerfHud));

      final backend =
          settingDescriptorById('shaders-backend')!
              as FtermEnumSettingDescriptor<ShaderBackendKind?>;
      expect(<ShaderBackendKind?>[
        for (final o in backend.optionsBuilder(linuxDesktop)) o.value,
      ], equals(<ShaderBackendKind?>[null, .disabled]));

      final ptyScope =
          settingDescriptorById('automation-pty-scope')!
              as FtermToggleSettingDescriptor;
      expect(ptyScope.settingsLabel, equals('Allow PTY Access'));
      expect(
        ptyScope.controlKey,
        equals(const ValueKey('automation-allow-pty-checkbox')),
      );

      final customWithReasons = <String>[
        'shaders-custom-path',
        'keyboard-ignored-chords',
        'shell-executable',
        'shell-arguments',
        'automation-port',
        'automation-password',
      ];
      for (final id in customWithReasons) {
        final custom =
            settingDescriptorById(id)! as FtermCustomSettingDescriptor;
        expect(custom.paletteExcludedReason, isNotNull);
        expect(custom.paletteExcludedReason, isNotEmpty);
      }
    });
  });

  group('read/write round-trips across all descriptors', () {
    test('round-trips every toggle, enum, and slider descriptor', () async {
      final workspace = _createWorkspace();
      addTearDown(workspace.dispose);

      for (final descriptor in allSettingDescriptors) {
        switch (descriptor) {
          case FtermToggleSettingDescriptor():
            final initial = descriptor.read(workspace);
            await descriptor.write(workspace, !initial);
            expect(
              descriptor.read(workspace),
              equals(!initial),
              reason: 'Toggle ${descriptor.id} failed to flip to ${!initial}',
            );
            await descriptor.write(workspace, initial);
            expect(
              descriptor.read(workspace),
              equals(initial),
              reason: 'Toggle ${descriptor.id} failed to restore $initial',
            );
          case FtermEnumSettingDescriptor():
            final ctx = descriptor.id == 'system-gpu-driver'
                ? windowsDesktop
                : linuxDesktop;
            await descriptor.accept(
              _EnumRoundTripVisitor(workspace: workspace, capabilities: ctx),
            );
          case FtermSliderSettingDescriptor():
            final target = (descriptor.min + descriptor.max) / 2;
            descriptor.write(workspace, target);
            expect(
              descriptor.read(workspace),
              closeTo(target, 0.01),
              reason: 'Slider ${descriptor.id} failed round-trip',
            );
            expect(descriptor.formatValue(target), isNotEmpty);
          case FtermCustomSettingDescriptor():
          case FtermActionDescriptor():
            break;
        }
      }
    });

    test('shell-preset switches options between POSIX and Windows', () {
      final workspace = _createWorkspace();
      addTearDown(workspace.dispose);

      final shellPreset =
          settingDescriptorById('shell-preset')!
              as FtermEnumSettingDescriptor<String?>;

      final posixOptions = shellPreset.optionsBuilder(linuxDesktop);
      expect(<String>[
        for (final o in posixOptions) o.idSuffix,
      ], equals(<String>['default', 'zsh', 'bash', 'sh']));
      expect(posixOptions.first.value, isNull);
      expect(posixOptions.first.label, equals(r'Default ($SHELL)'));

      final winOptions = shellPreset.optionsBuilder(windowsDesktop);
      expect(<String>[
        for (final o in winOptions) o.idSuffix,
      ], equals(<String>['default', 'pwsh', 'powershell', 'cmd']));
      expect(winOptions.first.value, isNull);
      expect(winOptions.first.label, equals('Default'));

      // Verify nullable String? write/read round-trip on Windows options.
      shellPreset.write(workspace, 'powershell.exe');
      expect(shellPreset.read(workspace), equals('powershell.exe'));
      shellPreset.write(workspace, null);
      expect(shellPreset.read(workspace), isNull);
    });

    test('keyboard-meta-policy computes dynamic platform/web summary text', () {
      final workspace = _createWorkspace();
      addTearDown(workspace.dispose);

      final meta =
          settingDescriptorById('keyboard-meta-policy')!
              as FtermEnumSettingDescriptor<FtermMetaKeyMode>;
      expect(
        meta.settingsHintKey,
        equals(const ValueKey('settings-meta-mode-summary')),
      );

      meta.write(workspace, .auto);
      expect(
        meta.settingsHintBuilder!(workspace, webLinux),
        equals('Auto (Web): passes unhandled Meta/Cmd chords to the browser.'),
      );
      expect(
        meta.settingsHintBuilder!(workspace, macDesktop),
        equals('Auto (macOS): passes unhandled Cmd chords to macOS.'),
      );
      expect(
        meta.settingsHintBuilder!(workspace, linuxDesktop),
        equals(
          'Auto (Desktop): claims unhandled Meta chords when Kitty keyboard '
          'protocol is active.',
        ),
      );

      meta.write(workspace, .passThrough);
      expect(
        meta.settingsHintBuilder!(workspace, webLinux),
        equals('Always passes unhandled Meta/Cmd chords to the browser.'),
      );
      expect(
        meta.settingsHintBuilder!(workspace, linuxDesktop),
        equals('Always passes unhandled Meta/Cmd chords to the OS.'),
      );

      meta.write(workspace, .kitty);
      expect(
        meta.settingsHintBuilder!(workspace, linuxDesktop),
        equals(
          'Claims unhandled Meta/Cmd chords when Kitty keyboard protocol is '
          'active; passes through in legacy mode.',
        ),
      );
    });
  });

  group('buildSettingDescriptorWidget renderer', () {
    testWidgets('renders exact ValueKeys for every declarative setting', (
      tester,
    ) async {
      final workspace = _createWorkspace();
      addTearDown(workspace.dispose);

      for (final descriptor in allSettingDescriptors) {
        final ctx = descriptor.id == 'system-gpu-driver'
            ? windowsDesktop
            : linuxDesktop;
        final widget = buildSettingDescriptorWidget(
          descriptor,
          workspace: workspace,
          palette: palette,
          capabilities: ctx,
        );
        await tester.pumpWidget(_wrapForWidgetTest(widget));

        switch (descriptor) {
          case FtermToggleSettingDescriptor():
            expect(
              find.byKey(descriptor.controlKey),
              findsOneWidget,
              reason: 'Missing toggle controlKey for ${descriptor.id}',
            );
          case FtermEnumSettingDescriptor():
            final info = descriptor.accept(_EnumOptionInspector(ctx));
            if (info.isDropdown) {
              expect(
                find.byKey(descriptor.dropdownKey!),
                findsOneWidget,
                reason: 'Missing dropdownKey for ${descriptor.id}',
              );
            } else {
              for (final optionKey in info.keys) {
                expect(
                  find.byKey(optionKey!),
                  findsOneWidget,
                  reason:
                      'Missing segmented key $optionKey for ${descriptor.id}',
                );
              }
            }
            if (descriptor.settingsHintKey case final hintKey?) {
              expect(
                find.byKey(hintKey),
                findsOneWidget,
                reason: 'Missing settingsHintKey for ${descriptor.id}',
              );
            }
          case FtermSliderSettingDescriptor():
            if (descriptor.usesCustomSettingsWidget) {
              expect(find.byType(BlenderSliderRow), findsNothing);
            } else {
              expect(
                find.byKey(descriptor.sliderKey!),
                findsOneWidget,
                reason: 'Missing sliderKey for ${descriptor.id}',
              );
              expect(
                find.byKey(descriptor.valueKey!),
                findsOneWidget,
                reason: 'Missing valueKey for ${descriptor.id}',
              );
            }
          case FtermCustomSettingDescriptor():
            expect(widget, isA<SizedBox>());
          case FtermActionDescriptor():
            break;
        }
      }
    });

    testWidgets(
      'handles async writes (shaders-backend), dropdowns, sliders, and '
      'onBeforeWrite',
      (tester) async {
        final workspace = _createWorkspace();
        addTearDown(workspace.dispose);

        var beforeWriteCount = 0;

        // 1. Async enum write (ShaderBackendKind?).
        final backend = settingDescriptorById('shaders-backend')!;
        await tester.pumpWidget(
          _wrapForWidgetTest(
            buildSettingDescriptorWidget(
              backend,
              workspace: workspace,
              palette: palette,
              capabilities: linuxDesktop,
              onBeforeWrite: () => beforeWriteCount++,
            ),
          ),
        );
        await tester.tap(
          find.byKey(const ValueKey('settings-shader-backend-disabled')),
        );
        await tester.pumpAndSettle();
        expect(
          workspace.shaderBackendOverride,
          equals(ShaderBackendKind.disabled),
        );
        expect(beforeWriteCount, equals(1));

        // 2. Segmented enum with onBeforeWrite (GPU Driver on Windows).
        final gpuDriver = settingDescriptorById('system-gpu-driver')!;
        await tester.pumpWidget(
          _wrapForWidgetTest(
            buildSettingDescriptorWidget(
              gpuDriver,
              workspace: workspace,
              palette: palette,
              capabilities: windowsDesktop,
              onBeforeWrite: () => beforeWriteCount++,
            ),
          ),
        );
        await tester.tap(
          find.byKey(const ValueKey('settings-gpu-driver-powerSaving')),
        );
        await tester.pump();
        expect(
          workspace.gpuDriverPreference,
          equals(GpuDriverPreference.powerSaving),
        );
        expect(beforeWriteCount, equals(2));

        // 3. Dropdown enum (Local CLI Shader Policy).
        final cliLocal = settingDescriptorById('shaders-cli-local-policy')!;
        await tester.pumpWidget(
          _wrapForWidgetTest(
            buildSettingDescriptorWidget(
              cliLocal,
              workspace: workspace,
              palette: palette,
              capabilities: linuxDesktop,
              onBeforeWrite: () => beforeWriteCount++,
            ),
          ),
        );
        await tester.tap(
          find.byKey(const ValueKey('settings-local-cli-shader-policy')),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Disabled').last);
        await tester.pumpAndSettle();
        expect(
          workspace.localCliShaderPolicy,
          equals(CliShaderPolicy.disabled),
        );
        expect(beforeWriteCount, equals(3));

        // 4. Toggle write.
        final copyOnSelect = settingDescriptorById('interface-copy-on-select')!;
        final initialCopy = workspace.copyOnSelect;
        await tester.pumpWidget(
          _wrapForWidgetTest(
            buildSettingDescriptorWidget(
              copyOnSelect,
              workspace: workspace,
              palette: palette,
              capabilities: linuxDesktop,
              onBeforeWrite: () => beforeWriteCount++,
            ),
          ),
        );
        await tester.tap(find.byKey(const ValueKey('settings-copy-on-select')));
        await tester.pump();
        expect(workspace.copyOnSelect, equals(!initialCopy));
        expect(beforeWriteCount, equals(4));

        // 5. Slider write.
        final bgOpacity = settingDescriptorById('themes-bg-opacity')!;
        await tester.pumpWidget(
          _wrapForWidgetTest(
            buildSettingDescriptorWidget(
              bgOpacity,
              workspace: workspace,
              palette: palette,
              capabilities: linuxDesktop,
              onBeforeWrite: () => beforeWriteCount++,
            ),
          ),
        );
        final slider = tester.widget<Slider>(
          find.byKey(const ValueKey('settings-background-opacity-slider')),
        );
        slider.onChanged!(0.42);
        await tester.pump();
        expect(workspace.backgroundOpacity, closeTo(0.42, 0.001));
        expect(beforeWriteCount, equals(5));
      },
    );

    testWidgets('hides descriptors and individual enum options gated by visibility or '
        'featureFlag', (tester) async {
      final workspace = _createWorkspace();
      addTearDown(workspace.dispose);

      // Visibility gating: Windows-only GPU driver hidden on Linux and Web.
      final gpuDriver = settingDescriptorById('system-gpu-driver')!;
      await tester.pumpWidget(
        _wrapForWidgetTest(
          buildSettingDescriptorWidget(
            gpuDriver,
            workspace: workspace,
            palette: palette,
            capabilities: linuxDesktop,
          ),
        ),
      );
      expect(find.byType(BlenderPropertyRow), findsNothing);

      // Action descriptor renders SizedBox.shrink().
      final syntheticAction = FtermActionDescriptor(
        id: 'test.action',
        category: 'Test',
        title: 'Test Action',
        icon: Icons.bolt,
        execute: (_) {},
      );
      await tester.pumpWidget(
        _wrapForWidgetTest(
          buildSettingDescriptorWidget(
            syntheticAction,
            workspace: workspace,
            palette: palette,
            capabilities: linuxDesktop,
          ),
        ),
      );
      expect(find.byType(BlenderPropertyRow), findsNothing);

      // Feature-flagged descriptor hidden when flag disabled, shown when enabled.
      final flaggedToggle = FtermToggleSettingDescriptor(
        id: 'test-flagged-toggle',
        paletteId: 'test.flagged_toggle',
        section: .system,
        panelId: 'test-panel',
        panelTitle: 'Test Panel',
        controlKey: const ValueKey('test-flagged-checkbox'),
        settingsLabel: 'Flagged Toggle',
        settingsCaption: 'Hidden unless experimental flag is enabled',
        paletteCategory: 'System',
        paletteTitle: 'Toggle Flagged',
        icon: Icons.flag_outlined,
        featureFlag: 'experimental_ui',
        read: (_) => false,
        write: (_, _) {},
      );
      await tester.pumpWidget(
        _wrapForWidgetTest(
          buildSettingDescriptorWidget(
            flaggedToggle,
            workspace: workspace,
            palette: palette,
            capabilities: linuxDesktop,
          ),
        ),
      );
      expect(find.byKey(const ValueKey('test-flagged-checkbox')), findsNothing);

      const withFlag = FtermCapabilityContext(
        isWeb: false,
        platform: .linux,
        isDesktopHost: true,
        supportsUpdates: true,
        enabledFeatures: <String>{'experimental_ui'},
      );
      await tester.pumpWidget(
        _wrapForWidgetTest(
          buildSettingDescriptorWidget(
            flaggedToggle,
            workspace: workspace,
            palette: palette,
            capabilities: withFlag,
          ),
        ),
      );
      expect(
        find.byKey(const ValueKey('test-flagged-checkbox')),
        findsOneWidget,
      );

      // Feature-flagged individual FtermEnumOption filtered out when disabled.
      var selectedValue = 'base';
      final flaggedEnum = FtermEnumSettingDescriptor<String>(
        id: 'test-flagged-enum',
        paletteIdPrefix: 'test.flagged_enum',
        section: .system,
        panelId: 'test-panel',
        panelTitle: 'Test Panel',
        settingsLabel: 'Flagged Mode',
        renderStyle: .segmented,
        paletteCategory: 'System',
        paletteTitlePrefix: 'Flagged Mode',
        icon: Icons.tune,
        optionsBuilder: (_) => <FtermEnumOption<String>>[
          const FtermEnumOption<String>(
            idSuffix: 'base',
            value: 'base',
            label: 'Base',
            settingsKey: ValueKey('test-enum-base'),
          ),
          const FtermEnumOption<String>(
            idSuffix: 'beta',
            value: 'beta',
            label: 'Beta',
            settingsKey: ValueKey('test-enum-beta'),
            featureFlag: 'experimental_ui',
          ),
          FtermEnumOption<String>(
            idSuffix: 'mac_only',
            value: 'mac_only',
            label: 'Mac Only',
            settingsKey: const ValueKey('test-enum-mac-only'),
            isAvailable: (ctx) => ctx.isMacOsDesktop,
          ),
        ],
        read: (_) => selectedValue,
        write: (_, v) => selectedValue = v,
      );

      await tester.pumpWidget(
        _wrapForWidgetTest(
          buildSettingDescriptorWidget(
            flaggedEnum,
            workspace: workspace,
            palette: palette,
            capabilities: linuxDesktop,
          ),
        ),
      );
      expect(find.byKey(const ValueKey('test-enum-base')), findsOneWidget);
      expect(find.byKey(const ValueKey('test-enum-beta')), findsNothing);
      expect(find.byKey(const ValueKey('test-enum-mac-only')), findsNothing);

      await tester.pumpWidget(
        _wrapForWidgetTest(
          buildSettingDescriptorWidget(
            flaggedEnum,
            workspace: workspace,
            palette: palette,
            capabilities: withFlag,
          ),
        ),
      );
      expect(find.byKey(const ValueKey('test-enum-base')), findsOneWidget);
      expect(find.byKey(const ValueKey('test-enum-beta')), findsOneWidget);
      expect(find.byKey(const ValueKey('test-enum-mac-only')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('test-enum-beta')));
      await tester.pump();
      expect(selectedValue, equals('beta'));

      await tester.pumpWidget(
        _wrapForWidgetTest(
          buildSettingDescriptorWidget(
            flaggedEnum,
            workspace: workspace,
            palette: palette,
            capabilities: macDesktop,
          ),
        ),
      );
      expect(find.byKey(const ValueKey('test-enum-mac-only')), findsOneWidget);

      // Nullable dropdown (int?) preserves null selection through pattern match.
      int? nullableDropdownValue = 60;
      final nullableDropdown = FtermEnumSettingDescriptor<int?>(
        id: 'test-nullable-dropdown',
        paletteIdPrefix: 'test.nullable_dropdown',
        section: .system,
        panelId: 'test-panel',
        panelTitle: 'Test Panel',
        settingsLabel: 'Nullable Limit',
        dropdownKey: const ValueKey('test-nullable-dropdown-key'),
        renderStyle: .dropdown,
        paletteCategory: 'System',
        paletteTitlePrefix: 'Nullable Limit',
        icon: Icons.tune,
        optionsBuilder: (_) => const <FtermEnumOption<int?>>[
          FtermEnumOption<int?>(
            idSuffix: 'none',
            value: null,
            label: 'Unlimited',
          ),
          FtermEnumOption<int?>(idSuffix: '60', value: 60, label: '60'),
        ],
        read: (_) => nullableDropdownValue,
        write: (_, v) => nullableDropdownValue = v,
      );
      await tester.pumpWidget(
        _wrapForWidgetTest(
          buildSettingDescriptorWidget(
            nullableDropdown,
            workspace: workspace,
            palette: palette,
            capabilities: linuxDesktop,
          ),
        ),
      );
      await tester.tap(
        find.byKey(const ValueKey('test-nullable-dropdown-key')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Unlimited').last);
      await tester.pumpAndSettle();
      expect(nullableDropdownValue, isNull);

      // Enum with zero visible options renders SizedBox.shrink().
      final allHiddenEnum = FtermEnumSettingDescriptor<String>(
        id: 'test-all-hidden-enum',
        paletteIdPrefix: 'test.hidden_enum',
        section: .system,
        panelId: 'test-panel',
        panelTitle: 'Test Panel',
        settingsLabel: 'Hidden Options',
        renderStyle: .segmented,
        paletteCategory: 'System',
        paletteTitlePrefix: 'Hidden',
        icon: Icons.tune,
        optionsBuilder: (_) => const <FtermEnumOption<String>>[
          FtermEnumOption<String>(
            idSuffix: 'only',
            value: 'only',
            label: 'Only',
            featureFlag: 'disabled_flag',
          ),
        ],
        read: (_) => 'only',
        write: (_, _) {},
      );
      await tester.pumpWidget(
        _wrapForWidgetTest(
          buildSettingDescriptorWidget(
            allHiddenEnum,
            workspace: workspace,
            palette: palette,
            capabilities: linuxDesktop,
          ),
        ),
      );
      expect(find.byType(BlenderPropertyRow), findsNothing);
    });
  });
}
