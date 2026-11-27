import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;

import '../workspace/fterm_workspace_controller.dart';

/// Runtime host capabilities and feature flags controlling command, setting,
/// enum option, and shortcut visibility across all `fterm` surfaces.
final class FtermCapabilityContext {
  /// Whether the app is running in Flutter Web / Wasm mode.
  final bool isWeb;

  /// Active target platform used for OS-specific controls and shortcut labels.
  final TargetPlatform platform;

  /// Whether a native desktop PTY host is available for local shell tabs.
  final bool isDesktopHost;

  /// Whether this build supports in-app release checks and self-updates.
  final bool supportsUpdates;

  /// Set of enabled runtime feature flag identifiers.
  final Set<String> enabledFeatures;

  /// Creates an immutable [FtermCapabilityContext].
  const FtermCapabilityContext({
    required this.isWeb,
    required this.platform,
    required this.isDesktopHost,
    required this.supportsUpdates,
    this.enabledFeatures = const <String>{},
  });

  /// Derives a [FtermCapabilityContext] from [workspace] with optional
  /// platform, runtime, capability, and feature-flag overrides.
  ///
  /// When [enabledFeatures] is omitted, inherits `workspace.enabledFeatures`.
  factory FtermCapabilityContext.fromWorkspace(
    FtermWorkspaceController workspace, {
    bool? isWeb,
    TargetPlatform? platform,
    bool? isDesktopHost,
    bool? supportsUpdates,
    Set<String>? enabledFeatures,
  }) => FtermCapabilityContext(
    isWeb: isWeb ?? kIsWeb,
    platform: platform ?? defaultTargetPlatform,
    isDesktopHost: isDesktopHost ?? workspace.isDesktopHost,
    supportsUpdates:
        supportsUpdates ?? workspace.updateViewModel.isSupportedDesktop,
    enabledFeatures: enabledFeatures ?? workspace.enabledFeatures,
  );

  /// Whether the active target platform is macOS (native or Web on macOS).
  bool get isMacOs => platform == .macOS;

  /// Whether the active target platform is Linux (native or Web on Linux).
  bool get isLinux => platform == .linux;

  /// Whether the active target platform is Windows (native or Web on Windows).
  bool get isWindows => platform == .windows;

  /// Whether the app is running natively on macOS desktop.
  bool get isMacOsDesktop => !isWeb && isMacOs;

  /// Whether the app is running natively on Linux desktop.
  bool get isLinuxDesktop => !isWeb && isLinux;

  /// Whether the app is running natively on Windows desktop.
  bool get isWindowsDesktop => !isWeb && isWindows;

  /// Whether native local desktop PTY shell capabilities are available.
  bool get hasLocalDesktopShell => !isWeb && isDesktopHost;

  /// Returns whether the runtime feature flag [flag] is enabled.
  bool isFeatureEnabled(String flag) => enabledFeatures.contains(flag);
}

/// Declarative platform and capability visibility gate shared across Settings
/// UI, Settings search, Command Palette, and Shortcut Dispatch.
enum FtermVisibility {
  /// Visible on every platform and runtime (desktop and Web).
  always,

  /// Visible on all native desktop builds (hidden on Web).
  desktopOnly,

  /// Visible only when native local desktop PTY shells are available.
  localDesktopShell,

  /// Visible only on native macOS desktop builds.
  macOsDesktop,

  /// Visible only on native Linux desktop builds.
  linuxDesktop,

  /// Visible only on native Windows desktop builds.
  windowsDesktop,

  /// Visible only on desktop builds that support self-updates.
  updatesSupported;

  /// Evaluates whether an item gated by this visibility is available in [ctx].
  bool isVisible(FtermCapabilityContext ctx) => switch (this) {
    .always => true,
    .desktopOnly => !ctx.isWeb,
    .localDesktopShell => ctx.hasLocalDesktopShell,
    .macOsDesktop => ctx.isMacOsDesktop,
    .linuxDesktop => ctx.isLinuxDesktop,
    .windowsDesktop => ctx.isWindowsDesktop,
    .updatesSupported => !ctx.isWeb && ctx.supportsUpdates,
  };
}
