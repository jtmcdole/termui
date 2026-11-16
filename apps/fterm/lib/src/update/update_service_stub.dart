import 'update_service.dart';

/// Creates the no-op Web [UpdateService] stub.
UpdateService createUpdateService() => const _WebStubUpdateService();

/// Always returns `false` on Web where `--internal-swap-update` does not apply.
Future<bool> maybeRunPlatformInternalSwapUpdate(List<String> args) async =>
    false;

final class _WebStubUpdateService implements UpdateService {
  const _WebStubUpdateService();

  @override
  FtermSemVer get currentVersion =>
      FtermSemVer.tryParse(kFtermBuildVersion) ?? FtermSemVer(0, 0, 0);

  @override
  SelfUpdateCapability get capability => SelfUpdateCapability.unsupportedWeb;

  @override
  Future<UpdateCheckOutcome> checkForUpdates({
    required bool includePrereleases,
    String? lastEtag,
    List<String> cachedTags = const [],
  }) async => UpdateCheckOutcome(
    availableUpdate: null,
    tagEtag: lastEtag,
    cachedTags: cachedTags,
    cacheTagState: false,
  );

  @override
  Future<StagedUpdate> stageUpdate(
    AvailableUpdate update, {
    void Function(DownloadProgress progress)? onProgress,
  }) => Future<StagedUpdate>.error(
    const UpdateException('Self-update is unsupported on Web.'),
  );

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
    List<String> relaunchArgs = const [],
    Future<void> Function()? beforeExitTeardown,
  }) => Future<void>.error(
    const UpdateException('Self-update is unsupported on Web.'),
  );

  @override
  Future<void> revealStagedInFinder(StagedUpdate staged) async {}

  @override
  Future<void> runStartupCleanup() async {}

  @override
  void dispose() {}
}
