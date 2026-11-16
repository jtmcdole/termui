import 'fterm_version.dart';
import 'update_models.dart';
import 'update_service_stub.dart'
    if (dart.library.io) 'update_service_io.dart'
    as impl;

export 'fterm_version.dart';
export 'update_models.dart';

/// Platform-neutral service boundary for desktop auto-update discovery,
/// staging, multi-instance lock coordination, and atomic bundle swapping.
abstract interface class UpdateService {
  /// Running build's semantic version.
  FtermSemVer get currentVersion;

  /// Self-update capability of the current installation root.
  SelfUpdateCapability get capability;

  /// Queries GitHub for a newer immutable release matching this host.
  Future<UpdateCheckOutcome> checkForUpdates({
    required bool includePrereleases,
    String? lastEtag,
    List<String> cachedTags = const [],
  });

  /// Downloads, verifies (`sha256:`), and extracts [update] into a private
  /// staging directory while holding `.fterm-update.lock`.
  Future<StagedUpdate> stageUpdate(
    AvailableUpdate update, {
    void Function(DownloadProgress progress)? onProgress,
  });

  /// Returns `true` when another `fterm` process from the same portable
  /// installation directory is currently running.
  bool hasSiblingInstances();

  /// Upgrades `.fterm-instance.lock` to exclusive prior to shutting down for a
  /// swap, returning `false` if a sibling instance is open.
  bool prepareExclusiveSwapLock();

  /// Releases an exclusive swap lock back to shared when a swap is aborted.
  void cancelExclusiveSwapLock();

  /// Executes the platform bundle swap for [staged], optionally relaunching
  /// `fterm` with [relaunchArgs], and terminates the current process.
  ///
  /// Throws [UpdateException] without exiting if an in-process pre-exit step
  /// (such as macOS `App Management` TCC) fails cleanly.
  Future<void> applyStagedUpdateAndExit(
    StagedUpdate staged, {
    required bool relaunch,
    List<String> relaunchArgs = const [],
    Future<void> Function()? beforeExitTeardown,
  });

  /// Reveals [staged] in macOS Finder (`open -R`) when `App Management` TCC
  /// blocks in-place `.app` replacement.
  Future<void> revealStagedInFinder(StagedUpdate staged);

  /// Schedules post-first-frame background cleanup of `*.fterm-bak` and
  /// `.fterm-update*` artifacts.
  Future<void> runStartupCleanup();

  /// Releases lock handles and HTTP sockets.
  void dispose();
}

/// Creates the platform [UpdateService] (desktop `dart:io` implementation or
/// no-op Web stub).
UpdateService createPlatformUpdateService() => impl.createUpdateService();

/// Runs the headless Windows `--internal-swap-update` routine when invoked from
/// `staged\fterm.exe`, returning `false` for normal application startups.
Future<bool> maybeRunInternalSwapUpdate(List<String> args) =>
    impl.maybeRunPlatformInternalSwapUpdate(args);
