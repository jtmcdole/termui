import 'dart:async';
import 'dart:ui' show AppExitResponse;

import 'package:clock/clock.dart';
import 'package:material_ui/material_ui.dart';
import 'package:termui/termui.dart' as tui;
import 'package:termui_cast_client_core/termui_cast_client_core.dart';

import 'about/about_service.dart';
import 'audio/fterm_audio_controller.dart';
import 'desktop_launch_env.dart';
import 'file_drop_bridge.dart';
import 'font_loader.dart';
import 'launch_config.dart';
import 'settings_storage.dart';
import 'ui/fterm_shell_scaffold.dart';
import 'update/update_service.dart';
import 'update/update_view_model.dart';
import 'workspace/fterm_workspace_controller.dart';
import 'workspace/local_host_driver.dart';

export 'launch_config.dart';

/// Root Flutter desktop and web terminal multiplexer & TermUI Caster client.
final class FtermApp extends StatefulWidget {
  /// Validated startup launch configuration.
  final CastLaunchConfig config;

  /// Optional binary channel factory seam (defaults to platform WebSockets).
  final ClientChannelFactory? channelFactory;

  /// Optional local shell host driver override (defaults to platform driver).
  final LocalHostDriver? localHostDriver;

  /// Optional audio controller factory seam for tests.
  final FtermAudioController Function()? audioControllerFactory;

  /// Monospace cell point size passed to the shared glyph atlas.
  final double fontSize;

  /// Initial multi-session tab bar dock placement.
  final DockPosition initialDockPosition;

  /// Viewport resize debounce duration.
  final Duration resizeDebounce;

  /// Optional callback invoked when a composited pane [tui.Buffer] updates.
  final void Function(tui.Buffer buffer)? onFrameRedrawn;

  /// Optional platform file-drop bridge factory seam.
  final FileDropBridgeFactory fileDropBridgeFactory;

  /// Optional external URL launcher seam invoked on `Ctrl/Cmd+Click`.
  final UrlOpener onOpenUrl;

  /// Optional settings storage seam (defaults to [defaultSettingsStorage]).
  final SettingsStorage? settingsStorage;

  /// Optional [Clock] seam for deterministic timing tests.
  final Clock? clock;

  /// Optional target platform override for shortcut and macOS inset tests.
  final TargetPlatform? platformOverride;

  /// Optional Web polarity override for Web vs Desktop tests.
  final bool? isWebOverride;

  /// Optional desktop update service seam for tests.
  final UpdateService? updateService;

  /// Optional update timer factory seam for deterministic tests.
  final UpdateTimerFactory? updateTimerFactory;

  /// Optional About metadata & license loader seam for deterministic tests.
  final AboutService? aboutService;

  /// Optional test hook invoked with the created [FtermWorkspaceController].
  final void Function(FtermWorkspaceController workspace)? onWorkspaceCreated;

  /// Creates the root `fterm` Flutter application.
  const FtermApp({
    super.key,
    required this.config,
    this.channelFactory,
    this.localHostDriver,
    this.audioControllerFactory,
    this.fontSize = 13.0,
    this.initialDockPosition = DockPosition.top,
    this.resizeDebounce = const Duration(milliseconds: 32),
    this.onFrameRedrawn,
    this.fileDropBridgeFactory = attachFileDropBridge,
    this.onOpenUrl = openExternalUrl,
    this.settingsStorage,
    this.clock,
    this.platformOverride,
    this.isWebOverride,
    this.updateService,
    this.updateTimerFactory,
    this.aboutService,
    this.onWorkspaceCreated,
  });

  @override
  State<FtermApp> createState() => _FtermAppState();
}

final class _FtermAppState extends State<FtermApp> with WidgetsBindingObserver {
  late FtermWorkspaceController _workspace;
  FileDropBridge? _fileDropBridge;
  Future<void>? _shutdownFuture;
  bool _isDraggingOverFiles = false;
  late ThemeMode _appThemeMode;

  static tui.TerminalBrightness _resolvePlatformBrightness() =>
      WidgetsBinding.instance.platformDispatcher.platformBrightness == .dark
      ? .dark
      : .light;

  @override
  void initState() {
    super.initState();
    scrubUrlFragment();
    WidgetsBinding.instance.addObserver(this);
    _fileDropBridge = widget.fileDropBridgeFactory(
      onDragHoverChanged: _handleDragHoverChanged,
      onFilesDropped: _handleFilesDropped,
    );
    _initWorkspace();
    unawaited(_workspace.start());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(_workspace.updateViewModel.runStartupCleanup());
    });
  }

  void _initWorkspace() {
    final transport = WsClientTransport(
      serverUri: widget.config.serverUri,
      token: widget.config.token,
      iapTokenProvider: widget.config.iapTokenProvider,
      channelFactory: widget.channelFactory,
    );
    String? lastLoggedError;
    final repository = CastClientRepository(
      transport: transport,
      onConnectError: (error) {
        final formatted = '$error';
        if (formatted == lastLoggedError) return;
        lastLoggedError = formatted;
        logDesktopConnectError(error);
      },
    );
    final storage = widget.settingsStorage ?? defaultSettingsStorage;
    final audio =
        widget.audioControllerFactory?.call() ??
        FtermAudioController(clock: widget.clock);
    final hostDriver = widget.localHostDriver ?? createLocalHostDriver();

    _workspace = FtermWorkspaceController(
      launchConfig: widget.config,
      repository: repository,
      localHostDriver: hostDriver,
      audioController: audio,
      storage: storage,
      defaultDockPosition: widget.initialDockPosition,
      defaultFontSize: widget.fontSize,
      initialBrightness: _resolvePlatformBrightness(),
      resizeDebounce: widget.resizeDebounce,
      clock: widget.clock,
      updateService: widget.updateService,
      updateTimerFactory: widget.updateTimerFactory,
      aboutService: widget.aboutService,
      onFrameRedrawn: widget.onFrameRedrawn,
    );
    _appThemeMode = _resolveMaterialThemeMode();
    _workspace.chromeNotifier.addListener(_onWorkspaceThemeChanged);
    widget.onWorkspaceCreated?.call(_workspace);
  }

  ThemeMode _resolveMaterialThemeMode() =>
      _workspace.activeTerminalTheme.brightness == tui.TerminalBrightness.light
      ? ThemeMode.light
      : ThemeMode.dark;

  void _onWorkspaceThemeChanged() {
    if (!mounted) return;
    final nextMode = _resolveMaterialThemeMode();
    if (nextMode != _appThemeMode) {
      setState(() => _appThemeMode = nextMode);
    }
  }

  void _handleDragHoverChanged(bool isDraggingOver) {
    if (!mounted || _isDraggingOverFiles == isDraggingOver) return;
    setState(() => _isDraggingOverFiles = isDraggingOver);
  }

  void _handleFilesDropped(List<DroppedFileSource> files) {
    if (files.isEmpty) return;
    _workspace.stageDroppedFiles(files);
  }

  @override
  void didChangePlatformBrightness() {
    super.didChangePlatformBrightness();
    _workspace.setPlatformBrightness(_resolvePlatformBrightness());
  }

  @override
  Future<AppExitResponse> didRequestAppExit() async {
    final updateVm = _workspace.updateViewModel;
    if (updateVm.applyOnQuit && updateVm.stagedUpdate != null) {
      final applied = await updateVm.applyStagedOnQuitIfArmed();
      if (!applied &&
          updateVm.capability ==
              SelfUpdateCapability.macosAppManagementDenied) {
        return AppExitResponse.cancel;
      }
    }
    await _shutdownBeforeExit();
    return AppExitResponse.exit;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.hidden || AppLifecycleState.paused:
        _workspace.flushPendingSettings();
        _workspace.setWorkspaceVisible(false);
        _workspace.setWindowFocused(false);
      case AppLifecycleState.inactive:
        _workspace.setWorkspaceVisible(true);
        _workspace.setWindowFocused(false);
      case AppLifecycleState.resumed:
        _workspace.setWorkspaceVisible(true);
        _workspace.setWindowFocused(true);
        _workspace.updateViewModel.onAppResumed();
      case AppLifecycleState.detached:
        unawaited(_shutdownBeforeExit());
    }
  }

  Future<void> _shutdownBeforeExit() {
    final existing = _shutdownFuture;
    if (existing != null) return existing;
    return _shutdownFuture = _runShutdownBeforeExit();
  }

  Future<void> _runShutdownBeforeExit() async {
    _workspace.flushPendingSettings();
    _fileDropBridge?.dispose();
    _fileDropBridge = null;
    try {
      await _workspace.dispose().timeout(const Duration(seconds: 2));
    } on TimeoutException {
      // Allow the app to finish terminating even if remote or audio teardown stalls.
    }
  }

  @override
  void reassemble() {
    super.reassemble();
    tui.TermuiBinding.reassembleAll();
  }

  @override
  void dispose() {
    _workspace.chromeNotifier.removeListener(_onWorkspaceThemeChanged);
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_shutdownBeforeExit());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'fterm',
      debugShowCheckedModeBanner: false,
      themeMode: _appThemeMode,
      theme: ThemeData(
        brightness: Brightness.light,
        fontFamily: castPrimaryFontFamily,
        fontFamilyFallback: castFallbackFontFamilies,
      ),
      darkTheme: ThemeData(
        brightness: Brightness.dark,
        fontFamily: castPrimaryFontFamily,
        fontFamilyFallback: castFallbackFontFamilies,
      ),
      home: FtermShellScaffold(
        workspace: _workspace,
        fontSize: widget.fontSize,
        onOpenUrl: widget.onOpenUrl,
        platformOverride: widget.platformOverride,
        isWebOverride: widget.isWebOverride,
        isDraggingOverFiles: _isDraggingOverFiles,
      ),
    );
  }
}
