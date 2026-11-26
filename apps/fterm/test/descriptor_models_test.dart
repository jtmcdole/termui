import 'package:flutter/foundation.dart' show TargetPlatform, ValueKey;
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:fterm/src/audio/fterm_audio_controller.dart';
import 'package:fterm/src/commands/fterm_capability_context.dart';
import 'package:fterm/src/commands/fterm_descriptor_models.dart';
import 'package:fterm/src/commands/fterm_shortcut_spec.dart';
import 'package:fterm/src/commands/shortcut_catalog.dart';
import 'package:fterm/src/launch_config.dart';
import 'package:fterm/src/settings_storage.dart';
import 'package:fterm/src/update/update_service.dart';
import 'package:fterm/src/workspace/fterm_workspace_controller.dart';
import 'package:fterm/src/workspace/local_host_driver.dart';
import 'package:material_ui/material_ui.dart' show Icons;
import 'package:termui/terminal/event.dart' as ev;
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

typedef _EnumRoundTripResult = ({
  String descriptorId,
  Type valueType,
  List<String> visibleSuffixes,
  Object? initialValue,
  Object? writtenValue,
});

/// Visitor verifying exact generic type `T` preservation across nullable and
/// non-nullable [FtermEnumSettingDescriptor] instances stored in a
/// heterogeneous `List<FtermDescriptor>`.
final class _RoundTripEnumVisitor
    implements FtermEnumDescriptorVisitor<_EnumRoundTripResult> {
  final FtermWorkspaceController workspace;
  final FtermCapabilityContext capabilities;

  const _RoundTripEnumVisitor({
    required this.workspace,
    required this.capabilities,
  });

  @override
  _EnumRoundTripResult visitEnum<T>(FtermEnumSettingDescriptor<T> descriptor) {
    final visibleOptions = <FtermEnumOption<T>>[
      for (final option in descriptor.optionsBuilder(capabilities))
        if (option.isVisibleFor(capabilities)) option,
    ];
    final initial = descriptor.read(workspace);
    final next = visibleOptions.last.value;
    descriptor.write(workspace, next);
    final afterWrite = descriptor.read(workspace);
    return (
      descriptorId: descriptor.id,
      valueType: T,
      visibleSuffixes: <String>[
        for (final option in visibleOptions) option.idSuffix,
      ],
      initialValue: initial,
      writtenValue: afterWrite,
    );
  }
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
  const desktopNoShell = FtermCapabilityContext(
    isWeb: false,
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
  const webLinux = FtermCapabilityContext(
    isWeb: true,
    platform: .linux,
    isDesktopHost: false,
    supportsUpdates: false,
  );
  const webWindows = FtermCapabilityContext(
    isWeb: true,
    platform: .windows,
    isDesktopHost: false,
    supportsUpdates: false,
  );
  const androidNative = FtermCapabilityContext(
    isWeb: false,
    platform: .android,
    isDesktopHost: false,
    supportsUpdates: false,
  );

  group('FtermCapabilityContext', () {
    test('exposes symmetric platform, desktop, and shell getters', () {
      expect(macDesktop.isMacOs, isTrue);
      expect(macDesktop.isLinux, isFalse);
      expect(macDesktop.isWindows, isFalse);
      expect(macDesktop.isMacOsDesktop, isTrue);
      expect(macDesktop.isLinuxDesktop, isFalse);
      expect(macDesktop.isWindowsDesktop, isFalse);
      expect(macDesktop.hasLocalDesktopShell, isTrue);

      expect(linuxDesktop.isMacOs, isFalse);
      expect(linuxDesktop.isLinux, isTrue);
      expect(linuxDesktop.isWindows, isFalse);
      expect(linuxDesktop.isMacOsDesktop, isFalse);
      expect(linuxDesktop.isLinuxDesktop, isTrue);
      expect(linuxDesktop.isWindowsDesktop, isFalse);
      expect(linuxDesktop.hasLocalDesktopShell, isTrue);

      expect(windowsDesktop.isMacOs, isFalse);
      expect(windowsDesktop.isLinux, isFalse);
      expect(windowsDesktop.isWindows, isTrue);
      expect(windowsDesktop.isMacOsDesktop, isFalse);
      expect(windowsDesktop.isLinuxDesktop, isFalse);
      expect(windowsDesktop.isWindowsDesktop, isTrue);
      expect(windowsDesktop.hasLocalDesktopShell, isTrue);

      expect(desktopNoShell.isLinux, isTrue);
      expect(desktopNoShell.isLinuxDesktop, isTrue);
      expect(desktopNoShell.hasLocalDesktopShell, isFalse);

      expect(webMac.isMacOs, isTrue);
      expect(webMac.isMacOsDesktop, isFalse);
      expect(webLinux.isLinux, isTrue);
      expect(webLinux.isLinuxDesktop, isFalse);
      expect(webWindows.isWindows, isTrue);
      expect(webWindows.isWindowsDesktop, isFalse);
      expect(webMac.hasLocalDesktopShell, isFalse);
    });

    test('tracks enabledFeatures with empty default', () {
      expect(linuxDesktop.enabledFeatures, isEmpty);
      expect(linuxDesktop.isFeatureEnabled('experimental_foo'), isFalse);

      const flagged = FtermCapabilityContext(
        isWeb: false,
        platform: .linux,
        isDesktopHost: true,
        supportsUpdates: true,
        enabledFeatures: <String>{'alpha', 'beta'},
      );
      expect(flagged.isFeatureEnabled('alpha'), isTrue);
      expect(flagged.isFeatureEnabled('beta'), isTrue);
      expect(flagged.isFeatureEnabled('gamma'), isFalse);
    });

    test('fromWorkspace derives capabilities and applies overrides', () {
      final supportedWs = _createWorkspace(
        isDesktopHost: true,
        supportsUpdates: true,
      );
      final limitedWs = _createWorkspace(
        isDesktopHost: false,
        supportsUpdates: false,
      );
      addTearDown(() async {
        await supportedWs.dispose();
        await limitedWs.dispose();
      });

      final derived = FtermCapabilityContext.fromWorkspace(
        supportedWs,
        isWeb: false,
        platform: .linux,
        enabledFeatures: const <String>{'feat.x'},
      );
      expect(derived.isWeb, isFalse);
      expect(derived.platform, equals(TargetPlatform.linux));
      expect(derived.isDesktopHost, isTrue);
      expect(derived.supportsUpdates, isTrue);
      expect(derived.hasLocalDesktopShell, isTrue);
      expect(derived.isFeatureEnabled('feat.x'), isTrue);

      final limited = FtermCapabilityContext.fromWorkspace(
        limitedWs,
        isWeb: false,
        platform: .windows,
      );
      expect(limited.isDesktopHost, isFalse);
      expect(limited.supportsUpdates, isFalse);
      expect(limited.hasLocalDesktopShell, isFalse);

      final overridden = FtermCapabilityContext.fromWorkspace(
        limitedWs,
        isWeb: true,
        platform: .macOS,
        isDesktopHost: true,
        supportsUpdates: true,
      );
      expect(overridden.isWeb, isTrue);
      expect(overridden.isMacOs, isTrue);
      expect(overridden.isMacOsDesktop, isFalse);
      expect(overridden.hasLocalDesktopShell, isFalse);
    });
  });

  group('FtermVisibility', () {
    test('evaluates every visibility mode across capability matrix', () {
      for (final ctx in const <FtermCapabilityContext>[
        macDesktop,
        linuxDesktop,
        windowsDesktop,
        desktopNoShell,
        webMac,
        webLinux,
        webWindows,
      ]) {
        expect(FtermVisibility.always.isVisible(ctx), isTrue);
      }

      expect(FtermVisibility.desktopOnly.isVisible(macDesktop), isTrue);
      expect(FtermVisibility.desktopOnly.isVisible(linuxDesktop), isTrue);
      expect(FtermVisibility.desktopOnly.isVisible(windowsDesktop), isTrue);
      expect(FtermVisibility.desktopOnly.isVisible(desktopNoShell), isTrue);
      expect(FtermVisibility.desktopOnly.isVisible(webMac), isFalse);
      expect(FtermVisibility.desktopOnly.isVisible(webLinux), isFalse);

      expect(FtermVisibility.localDesktopShell.isVisible(macDesktop), isTrue);
      expect(
        FtermVisibility.localDesktopShell.isVisible(desktopNoShell),
        isFalse,
      );
      expect(FtermVisibility.localDesktopShell.isVisible(webMac), isFalse);

      expect(FtermVisibility.macOsDesktop.isVisible(macDesktop), isTrue);
      expect(FtermVisibility.macOsDesktop.isVisible(linuxDesktop), isFalse);
      expect(FtermVisibility.macOsDesktop.isVisible(windowsDesktop), isFalse);
      expect(FtermVisibility.macOsDesktop.isVisible(webMac), isFalse);

      expect(FtermVisibility.linuxDesktop.isVisible(linuxDesktop), isTrue);
      expect(FtermVisibility.linuxDesktop.isVisible(macDesktop), isFalse);
      expect(FtermVisibility.linuxDesktop.isVisible(windowsDesktop), isFalse);
      expect(FtermVisibility.linuxDesktop.isVisible(webLinux), isFalse);

      expect(FtermVisibility.windowsDesktop.isVisible(windowsDesktop), isTrue);
      expect(FtermVisibility.windowsDesktop.isVisible(macDesktop), isFalse);
      expect(FtermVisibility.windowsDesktop.isVisible(linuxDesktop), isFalse);
      expect(FtermVisibility.windowsDesktop.isVisible(webWindows), isFalse);

      expect(FtermVisibility.updatesSupported.isVisible(macDesktop), isTrue);
      expect(FtermVisibility.updatesSupported.isVisible(linuxDesktop), isTrue);
      expect(
        FtermVisibility.updatesSupported.isVisible(windowsDesktop),
        isFalse,
      );
      const webWithUpdatesFlag = FtermCapabilityContext(
        isWeb: true,
        platform: .linux,
        isDesktopHost: false,
        supportsUpdates: true,
      );
      expect(
        FtermVisibility.updatesSupported.isVisible(webWithUpdatesFlag),
        isFalse,
      );
    });
  });

  group('FtermKeyStroke and FtermLeaderChord', () {
    test('FtermKeyStroke enforces exact key and exact modifier set', () {
      const stroke = FtermKeyStroke(
        LogicalKeyboardKey.f10,
        ctrl: true,
        shift: true,
      );
      expect(
        stroke.matches(LogicalKeyboardKey.f10, const <ev.Modifier>{
          .control,
          .shift,
        }),
        isTrue,
      );
      expect(
        stroke.matches(LogicalKeyboardKey.f10, const <ev.Modifier>{.control}),
        isFalse,
      );
      expect(
        stroke.matches(LogicalKeyboardKey.f10, const <ev.Modifier>{
          .control,
          .shift,
          .alt,
        }),
        isFalse,
      );
      expect(
        stroke.matches(LogicalKeyboardKey.f10, const <ev.Modifier>{
          .control,
          .shift,
          .meta,
        }),
        isFalse,
      );
      expect(
        stroke.matches(LogicalKeyboardKey.f9, const <ev.Modifier>{
          .control,
          .shift,
        }),
        isFalse,
      );
    });

    test('FtermLeaderChord handles shift rules, alternates, and layouts', () {
      const plain = FtermLeaderChord(LogicalKeyboardKey.keyZ);
      expect(plain.matches(LogicalKeyboardKey.keyZ, shift: false), isTrue);
      expect(plain.matches(LogicalKeyboardKey.keyZ, shift: true), isTrue);
      expect(plain.matches(LogicalKeyboardKey.keyX, shift: false), isFalse);

      const shiftedOnly = FtermLeaderChord(
        LogicalKeyboardKey.keyP,
        requireShift: true,
      );
      expect(shiftedOnly.matches(LogicalKeyboardKey.keyP, shift: true), isTrue);
      expect(
        shiftedOnly.matches(LogicalKeyboardKey.keyP, shift: false),
        isFalse,
      );

      const unshiftedOnly = FtermLeaderChord(
        LogicalKeyboardKey.keyP,
        forbidShift: true,
      );
      expect(
        unshiftedOnly.matches(LogicalKeyboardKey.keyP, shift: false),
        isTrue,
      );
      expect(
        unshiftedOnly.matches(LogicalKeyboardKey.keyP, shift: true),
        isFalse,
      );

      expect(
        () => FtermLeaderChord(
          LogicalKeyboardKey.keyP,
          requireShift: true,
          forbidShift: true,
        ),
        throwsAssertionError,
      );

      expect(
        FtermShortcuts.emergencyStopShaders.leaderChord!.matches(
          LogicalKeyboardKey.numpad0,
          shift: false,
        ),
        isTrue,
      );
      expect(
        FtermShortcuts.cycleDockPosition.leaderChord!.matches(
          LogicalKeyboardKey.space,
          shift: false,
        ),
        isTrue,
      );
      expect(
        FtermShortcuts.openHelp.leaderChord!.matches(
          LogicalKeyboardKey.slash,
          shift: true,
        ),
        isTrue,
      );
      expect(
        FtermShortcuts.openHelp.leaderChord!.matches(
          LogicalKeyboardKey.slash,
          shift: false,
        ),
        isFalse,
      );
      expect(
        FtermShortcuts.openHelp.leaderChord!.matches(
          LogicalKeyboardKey.keyA,
          shift: false,
          character: '?',
        ),
        isTrue,
      );
      // Unshifted backslash stays free for Ctrl+\ \ passthrough.
      expect(
        FtermShortcuts.splitRight.leaderChord!.matches(
          LogicalKeyboardKey.backslash,
          shift: false,
        ),
        isFalse,
      );
      expect(
        FtermShortcuts.splitRight.leaderChord!.matches(
          LogicalKeyboardKey.backslash,
          shift: true,
        ),
        isTrue,
      );
      // Unshifted digit5 stays free for tab selection.
      expect(
        FtermShortcuts.splitRight.leaderChord!.matches(
          LogicalKeyboardKey.digit5,
          shift: false,
        ),
        isFalse,
      );
      expect(
        FtermShortcuts.splitRight.leaderChord!.matches(
          LogicalKeyboardKey.digit5,
          shift: true,
        ),
        isTrue,
      );
    });
  });

  group('FtermShortcutBinding and FtermShortcuts', () {
    test('formatPaletteHint respects desktopOnlyHint and OS conventions', () {
      // Desktop-only with no leader chord -> null on Web.
      expect(
        FtermShortcuts.reloadShaders.formatPaletteHint(linuxDesktop),
        equals('Ctrl+Shift+F5'),
      );
      expect(
        FtermShortcuts.reloadShaders.formatPaletteHint(macDesktop),
        equals('Ctrl+Shift+F5'),
      );
      expect(FtermShortcuts.reloadShaders.formatPaletteHint(webLinux), isNull);

      expect(
        FtermShortcuts.togglePerfHud.formatPaletteHint(windowsDesktop),
        equals('Ctrl+Shift+F9'),
      );
      expect(FtermShortcuts.togglePerfHud.formatPaletteHint(webMac), isNull);

      expect(
        FtermShortcuts.toggleTraceRecording.formatPaletteHint(linuxDesktop),
        equals('Ctrl+Shift+F10'),
      );
      expect(
        FtermShortcuts.toggleTraceRecording.formatPaletteHint(webWindows),
        isNull,
      );

      expect(
        FtermShortcuts.newLocalShell.formatPaletteHint(macDesktop),
        equals('Cmd+T'),
      );
      expect(
        FtermShortcuts.newLocalShell.formatPaletteHint(linuxDesktop),
        equals('Ctrl+Shift+T'),
      );
      expect(FtermShortcuts.newLocalShell.formatPaletteHint(webMac), isNull);

      // Desktop-only label WITH leader fallback -> falls back on Web.
      expect(
        FtermShortcuts.splitRight.formatPaletteHint(macDesktop),
        equals('Cmd+D'),
      );
      expect(
        FtermShortcuts.splitRight.formatPaletteHint(linuxDesktop),
        equals('Ctrl+Shift+D'),
      );
      expect(
        FtermShortcuts.splitRight.formatPaletteHint(webMac),
        equals(r'Ctrl+\ |'),
      );

      expect(
        FtermShortcuts.splitDown.formatPaletteHint(macDesktop),
        equals('Cmd+Shift+D'),
      );
      expect(
        FtermShortcuts.splitDown.formatPaletteHint(windowsDesktop),
        equals('Ctrl+Shift+E'),
      );
      expect(
        FtermShortcuts.splitDown.formatPaletteHint(webLinux),
        equals(r'Ctrl+\ -'),
      );

      expect(
        FtermShortcuts.closePane.formatPaletteHint(macDesktop),
        equals('Cmd+W'),
      );
      expect(
        FtermShortcuts.closePane.formatPaletteHint(linuxDesktop),
        equals('Ctrl+Shift+W'),
      );
      expect(
        FtermShortcuts.closePane.formatPaletteHint(webWindows),
        equals(r'Ctrl+\ x'),
      );

      expect(
        FtermShortcuts.commandPalette.formatPaletteHint(macDesktop),
        equals('Cmd+Shift+P'),
      );
      expect(
        FtermShortcuts.commandPalette.formatPaletteHint(linuxDesktop),
        equals('Ctrl+Shift+P'),
      );
      expect(
        FtermShortcuts.commandPalette.formatPaletteHint(webLinux),
        equals(r'Ctrl+\ Shift+P'),
      );

      // Cross-runtime bindings (desktopOnlyHint: false) remain visible on Web.
      expect(
        FtermShortcuts.fontIncrease.formatPaletteHint(webMac),
        equals('Cmd+='),
      );
      expect(
        FtermShortcuts.fontIncrease.formatPaletteHint(webLinux),
        equals('Ctrl+='),
      );
      expect(
        FtermShortcuts.fontDecrease.formatPaletteHint(macDesktop),
        equals('Cmd+-'),
      );
      expect(
        FtermShortcuts.fontReset.formatPaletteHint(windowsDesktop),
        equals('Ctrl+0'),
      );
      expect(
        FtermShortcuts.emergencyStopShaders.formatPaletteHint(webMac),
        equals('Ctrl+Shift+F6'),
      );

      // Leader-only palette label stays consistent everywhere.
      expect(
        FtermShortcuts.openSettings.formatPaletteHint(macDesktop),
        equals(r'Ctrl+\ ,'),
      );
      expect(
        FtermShortcuts.openSettings.formatPaletteHint(webLinux),
        equals(r'Ctrl+\ ,'),
      );
    });

    test('matchesDesktopStroke gates Web and separates macOS vs Linux/Win', () {
      const ctrlShift = <ev.Modifier>{.control, .shift};
      const metaShift = <ev.Modifier>{.meta, .shift};
      const metaOnly = <ev.Modifier>{.meta};

      // Universal desktop strokes match all desktop OSes, never Web.
      expect(
        FtermShortcuts.toggleTraceRecording.matchesDesktopStroke(
          LogicalKeyboardKey.f10,
          ctrlShift,
          macDesktop,
        ),
        isTrue,
      );
      expect(
        FtermShortcuts.toggleTraceRecording.matchesDesktopStroke(
          LogicalKeyboardKey.f10,
          ctrlShift,
          linuxDesktop,
        ),
        isTrue,
      );
      expect(
        FtermShortcuts.toggleTraceRecording.matchesDesktopStroke(
          LogicalKeyboardKey.f10,
          ctrlShift,
          windowsDesktop,
        ),
        isTrue,
      );
      expect(
        FtermShortcuts.toggleTraceRecording.matchesDesktopStroke(
          LogicalKeyboardKey.f10,
          ctrlShift,
          webLinux,
        ),
        isFalse,
      );

      // macOS vs Linux/Windows OS strokes stay isolated.
      expect(
        FtermShortcuts.commandPalette.matchesDesktopStroke(
          LogicalKeyboardKey.keyP,
          metaShift,
          macDesktop,
        ),
        isTrue,
      );
      expect(
        FtermShortcuts.commandPalette.matchesDesktopStroke(
          LogicalKeyboardKey.keyP,
          ctrlShift,
          macDesktop,
        ),
        isFalse,
      );
      expect(
        FtermShortcuts.commandPalette.matchesDesktopStroke(
          LogicalKeyboardKey.keyP,
          ctrlShift,
          linuxDesktop,
        ),
        isTrue,
      );
      expect(
        FtermShortcuts.commandPalette.matchesDesktopStroke(
          LogicalKeyboardKey.keyP,
          ctrlShift,
          windowsDesktop,
        ),
        isTrue,
      );
      expect(
        FtermShortcuts.commandPalette.matchesDesktopStroke(
          LogicalKeyboardKey.keyP,
          metaShift,
          windowsDesktop,
        ),
        isFalse,
      );
      expect(
        FtermShortcuts.commandPalette.matchesDesktopStroke(
          LogicalKeyboardKey.keyP,
          ctrlShift,
          androidNative,
        ),
        isFalse,
      );

      // Settings Cmd+, on macOS and Ctrl+Shift+, on Linux/Windows.
      expect(
        FtermShortcuts.openSettings.matchesDesktopStroke(
          LogicalKeyboardKey.comma,
          metaOnly,
          macDesktop,
        ),
        isTrue,
      );
      expect(
        FtermShortcuts.openSettings.matchesDesktopStroke(
          LogicalKeyboardKey.comma,
          ctrlShift,
          linuxDesktop,
        ),
        isTrue,
      );
      expect(
        FtermShortcuts.openSettings.matchesDesktopStroke(
          LogicalKeyboardKey.comma,
          metaOnly,
          webMac,
        ),
        isFalse,
      );
    });

    test('buildHelpShortcutEntries preserves canonical grouped Help rows', () {
      final entries = buildHelpShortcutEntries();
      final keys = <String>[for (final entry in entries) entry.keys];

      expect(keys, contains('Ctrl+Shift+P / Cmd+Shift+P'));
      expect(keys, contains(r'Ctrl+\ then Shift+P'));
      expect(keys, contains(r'Ctrl+\ then e'));
      expect(keys, contains('Cmd+= / Cmd+- / Cmd+0'));
      expect(keys, contains('Ctrl+= / Ctrl+- / Ctrl+0'));
      expect(keys, contains('Ctrl+Shift+F5'));
      expect(keys, contains(r'Ctrl+Shift+F6 / Ctrl+\ 0'));
      expect(keys, contains('Ctrl+Shift+F9'));
      expect(keys, contains('Ctrl+Shift+F10'));

      final traceRow = entries.firstWhere((e) => e.keys == 'Ctrl+Shift+F10');
      expect(traceRow.description.toLowerCase(), contains('trace'));
      expect(
        () => entries.add((keys: 'x', description: 'y')),
        throwsUnsupportedError,
      );
    });
  });

  group('FtermDescriptor, FtermEnumOption, and FtermEnumDescriptorVisitor', () {
    test('isVisibleFor combines visibility, featureFlag, and isAvailable', () {
      final action = FtermActionDescriptor(
        id: 'test.gated_action',
        category: 'Test',
        title: 'Gated Action',
        icon: Icons.bolt,
        visibility: .linuxDesktop,
        featureFlag: 'flag.alpha',
        isAvailable: (ctx) => ctx.supportsUpdates,
        execute: (_) {},
      );

      expect(action.isVisibleFor(linuxDesktop), isFalse);

      const linuxFlagged = FtermCapabilityContext(
        isWeb: false,
        platform: .linux,
        isDesktopHost: true,
        supportsUpdates: true,
        enabledFeatures: <String>{'flag.alpha'},
      );
      expect(action.isVisibleFor(linuxFlagged), isTrue);

      const linuxFlaggedNoUpdates = FtermCapabilityContext(
        isWeb: false,
        platform: .linux,
        isDesktopHost: true,
        supportsUpdates: false,
        enabledFeatures: <String>{'flag.alpha'},
      );
      expect(action.isVisibleFor(linuxFlaggedNoUpdates), isFalse);

      const macFlagged = FtermCapabilityContext(
        isWeb: false,
        platform: .macOS,
        isDesktopHost: true,
        supportsUpdates: true,
        enabledFeatures: <String>{'flag.alpha'},
      );
      expect(action.isVisibleFor(macFlagged), isFalse);
    });

    test('FtermEnumOption.isVisibleFor gates options cleanly', () {
      const option = FtermEnumOption<String>(
        idSuffix: 'beta',
        value: 'beta',
        label: 'Beta Option',
        visibility: .desktopOnly,
        featureFlag: 'flag.beta',
      );

      expect(option.isVisibleFor(linuxDesktop), isFalse);
      expect(
        option.isVisibleFor(
          const FtermCapabilityContext(
            isWeb: true,
            platform: .linux,
            isDesktopHost: false,
            supportsUpdates: false,
            enabledFeatures: <String>{'flag.beta'},
          ),
        ),
        isFalse,
      );
      expect(
        option.isVisibleFor(
          const FtermCapabilityContext(
            isWeb: false,
            platform: .linux,
            isDesktopHost: true,
            supportsUpdates: true,
            enabledFeatures: <String>{'flag.beta'},
          ),
        ),
        isTrue,
      );
    });

    test('validates descriptor constructor invariants in debug mode', () {
      expect(
        () => FtermActionDescriptor(
          id: '',
          category: 'Test',
          title: 'Empty Id',
          icon: Icons.bolt,
          execute: (_) {},
        ),
        throwsAssertionError,
      );
      expect(
        () => FtermSliderSettingDescriptor(
          id: 'slider.bad_bounds',
          paletteId: 'slider.bad_bounds',
          section: .themes,
          panelId: 'p',
          panelTitle: 'P',
          label: 'Bad',
          paletteCategory: 'Appearance',
          icon: Icons.tune,
          min: 1.0,
          max: 1.0,
          step: 0.1,
          formatValue: (v) => '$v',
          read: (_) => 1.0,
          write: (_, _) {},
        ),
        throwsAssertionError,
      );
      expect(
        () => FtermSliderSettingDescriptor(
          id: 'slider.bad_step',
          paletteId: 'slider.bad_step',
          section: .themes,
          panelId: 'p',
          panelTitle: 'P',
          label: 'Bad',
          paletteCategory: 'Appearance',
          icon: Icons.tune,
          min: 0.0,
          max: 1.0,
          step: 0.0,
          formatValue: (v) => '$v',
          read: (_) => 0.5,
          write: (_, _) {},
        ),
        throwsAssertionError,
      );
      expect(
        () => FtermSliderSettingDescriptor(
          id: 'slider.bad_divisions',
          paletteId: 'slider.bad_divisions',
          section: .themes,
          panelId: 'p',
          panelTitle: 'P',
          label: 'Bad',
          paletteCategory: 'Appearance',
          icon: Icons.tune,
          min: 0.0,
          max: 1.0,
          step: 0.1,
          divisions: 0,
          formatValue: (v) => '$v',
          read: (_) => 0.5,
          write: (_, _) {},
        ),
        throwsAssertionError,
      );
    });

    test('FtermEnumDescriptorVisitor preserves nullable and non-nullable T in '
        'heterogeneous List<FtermDescriptor>', () async {
      final ws = _createWorkspace();
      addTearDown(ws.dispose);

      int? storedFps = 60;
      String? storedShell = 'zsh';
      ShaderBackendKind? storedBackend;
      var storedDock = DockPosition.top;

      final descriptors = <FtermDescriptor>[
        FtermActionDescriptor(
          id: 'action.noop',
          category: 'Test',
          title: 'No-Op',
          icon: Icons.bolt,
          execute: (_) {},
        ),
        FtermToggleSettingDescriptor(
          id: 'toggle.demo',
          paletteId: 'settings.toggle.demo',
          section: .interface,
          panelId: 'p',
          panelTitle: 'P',
          controlKey: const ValueKey<String>('toggle-demo'),
          settingsLabel: 'Demo',
          settingsCaption: 'Caption',
          paletteCategory: 'Settings',
          paletteTitle: 'Toggle Demo',
          icon: Icons.tune,
          read: (_) => false,
          write: (_, _) {},
        ),
        FtermSliderSettingDescriptor(
          id: 'slider.custom_widget',
          paletteId: 'appearance.font_size',
          section: .themes,
          panelId: 'themes-typography',
          panelTitle: 'Typography',
          label: 'Font Size',
          paletteCategory: 'Appearance',
          icon: Icons.format_size,
          min: 8.0,
          max: 32.0,
          step: 1.0,
          usesCustomSettingsWidget: true,
          formatValue: (v) => '${v.toInt()} pt',
          read: (_) => 14.0,
          write: (_, _) {},
        ),
        const FtermCustomSettingDescriptor(
          id: 'custom.demo',
          section: .shell,
          panelId: 'shell-exec',
          panelTitle: 'Shell',
          title: 'Executable',
          paletteExcludedReason: 'Free-form text field in Settings only.',
        ),
        FtermEnumSettingDescriptor<int?>(
          id: 'shaders-max-fps',
          paletteIdPrefix: 'shader.max_fps',
          section: .shaders,
          panelId: 'shaders-pacing',
          panelTitle: 'Frame Pacing',
          settingsLabel: 'Max Shader FPS',
          renderStyle: .segmented,
          paletteCategory: 'Shader',
          paletteTitlePrefix: 'Max FPS',
          icon: Icons.speed,
          optionsBuilder: (_) => const <FtermEnumOption<int?>>[
            FtermEnumOption<int?>(idSuffix: '60', value: 60, label: '60 FPS'),
            FtermEnumOption<int?>(
              idSuffix: 'uncapped',
              value: null,
              label: 'Uncapped',
            ),
            FtermEnumOption<int?>(
              idSuffix: 'hidden',
              value: 240,
              label: '240 FPS',
              featureFlag: 'flag.240fps',
            ),
          ],
          read: (_) => storedFps,
          write: (_, v) => storedFps = v,
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
          icon: Icons.terminal,
          optionsBuilder: (_) => const <FtermEnumOption<String?>>[
            FtermEnumOption<String?>(
              idSuffix: 'zsh',
              value: 'zsh',
              label: 'zsh',
            ),
            FtermEnumOption<String?>(
              idSuffix: 'default',
              value: null,
              label: 'Default',
            ),
          ],
          read: (_) => storedShell,
          write: (_, v) => storedShell = v,
        ),
        FtermEnumSettingDescriptor<ShaderBackendKind?>(
          id: 'shaders-backend',
          paletteIdPrefix: 'shader.backend',
          section: .shaders,
          panelId: 'shaders-runtime',
          panelTitle: 'Runtime',
          settingsLabel: 'Shader Backend',
          renderStyle: .segmented,
          paletteCategory: 'Shader',
          paletteTitlePrefix: 'Backend',
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
          read: (_) => storedBackend,
          write: (_, v) => storedBackend = v,
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
          read: (_) => storedDock,
          write: (_, v) => storedDock = v,
        ),
      ];

      final visitor = _RoundTripEnumVisitor(
        workspace: ws,
        capabilities: linuxDesktop,
      );
      final kinds = <String>[];
      final enumResults = <String, _EnumRoundTripResult>{};

      for (final descriptor in descriptors) {
        switch (descriptor) {
          case FtermActionDescriptor():
            kinds.add('action');
          case FtermToggleSettingDescriptor():
            kinds.add('toggle');
          case FtermSliderSettingDescriptor():
            expect(descriptor.usesCustomSettingsWidget, isTrue);
            expect(descriptor.sliderKey, isNull);
            expect(descriptor.valueKey, isNull);
            kinds.add('slider');
          case FtermCustomSettingDescriptor():
            expect(descriptor.paletteExcludedReason, isNotNull);
            kinds.add('custom');
          case FtermEnumSettingDescriptor<Object?>():
            kinds.add('enum');
            final result = descriptor.accept(visitor);
            enumResults[result.descriptorId] = result;
        }
      }

      expect(
        kinds,
        equals(const <String>[
          'action',
          'toggle',
          'slider',
          'custom',
          'enum',
          'enum',
          'enum',
          'enum',
        ]),
      );

      final fpsResult = enumResults['shaders-max-fps']!;
      expect(fpsResult.valueType, equals(typeOf<int?>()));
      expect(
        fpsResult.visibleSuffixes,
        equals(const <String>['60', 'uncapped']),
      );
      expect(fpsResult.initialValue, equals(60));
      expect(fpsResult.writtenValue, isNull);
      expect(storedFps, isNull);

      final shellResult = enumResults['shell-preset']!;
      expect(shellResult.valueType, equals(typeOf<String?>()));
      expect(shellResult.initialValue, equals('zsh'));
      expect(shellResult.writtenValue, isNull);
      expect(storedShell, isNull);

      final backendResult = enumResults['shaders-backend']!;
      expect(backendResult.valueType, equals(typeOf<ShaderBackendKind?>()));
      expect(backendResult.initialValue, isNull);
      expect(backendResult.writtenValue, equals(ShaderBackendKind.disabled));
      expect(storedBackend, equals(ShaderBackendKind.disabled));

      final dockResult = enumResults['interface-dock-position']!;
      expect(dockResult.valueType, equals(DockPosition));
      expect(dockResult.initialValue, equals(DockPosition.top));
      expect(dockResult.writtenValue, equals(DockPosition.left));
      expect(storedDock, equals(DockPosition.left));
    });
  });
}

Type typeOf<T>() => T;
