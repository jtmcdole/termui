import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';

import 'package:flutter/foundation.dart' show kReleaseMode, visibleForTesting;
import 'package:path/path.dart' as p;

import 'archive_validator_io.dart';
import 'portable_lock_io.dart';
import 'swapper_io.dart';
import 'update_repository_io.dart';
import 'update_service.dart';

/// Minimum 250 MB free-disk headroom required before downloading/extracting.
const int kRequiredFreeDiskHeadroomBytes = 250 * 1024 * 1024;

/// Resolved filesystem layout for a portable desktop `fterm` installation.
final class PortableInstallLayout {
  /// Host OS identifier (`windows`, `linux`, or `macos`).
  final String operatingSystem;

  /// Resolved capability of this installation root.
  final SelfUpdateCapability capability;

  /// Portable bundle root (`<Dir>` on Windows/Linux, `<Parent>/<App>.app` on macOS),
  /// or `null` when non-portable.
  final String? portableRootPath;

  /// Enclosing directory holding `.fterm-instance.lock` and `.fterm-update.lock`
  /// (`<Dir>` on Windows/Linux, `<Parent>` on macOS).
  final String? lockAndCleanupDirPath;

  /// Private staging directory path (`<Dir>/.fterm-update` or
  /// `<Parent>/.fterm-update-<uid>-<nonce>`).
  final String? stagingDirPath;

  /// Creates an immutable [PortableInstallLayout].
  const PortableInstallLayout({
    required this.operatingSystem,
    required this.capability,
    this.portableRootPath,
    this.lockAndCleanupDirPath,
    this.stagingDirPath,
  });
}

/// Resolves the [PortableInstallLayout] from [resolvedExecutable] and host
/// pre-flight guards (`kReleaseMode`, `FLUTTER_TEST`, path blocklists, bundle
/// structure, and write/TCC probes).
PortableInstallLayout resolvePortableInstallLayout({
  String? resolvedExecutable,
  String? operatingSystem,
  Map<String, String>? environment,
  bool? releaseMode,
  int? posixUid,
  String? stagingNonce,
}) {
  final os = operatingSystem ?? Platform.operatingSystem;
  final env = environment ?? Platform.environment;
  final isRelease = releaseMode ?? kReleaseMode;
  final exePath = resolvedExecutable ?? Platform.resolvedExecutable;

  if (!isRelease || env.containsKey('FLUTTER_TEST')) {
    return PortableInstallLayout(
      operatingSystem: os,
      capability: SelfUpdateCapability.readOnlyOrNonPortable,
    );
  }
  if (_isBlockedInstallPath(exePath)) {
    return PortableInstallLayout(
      operatingSystem: os,
      capability: SelfUpdateCapability.readOnlyOrNonPortable,
    );
  }
  return switch (os) {
    'windows' => _resolveWindowsLayout(exePath),
    'linux' => _resolveLinuxLayout(exePath),
    'macos' => _resolveMacosLayout(
      exePath,
      posixUid: posixUid,
      stagingNonce: stagingNonce,
    ),
    _ => PortableInstallLayout(
      operatingSystem: os,
      capability: SelfUpdateCapability.readOnlyOrNonPortable,
    ),
  };
}

bool _isBlockedInstallPath(String exePath) {
  final forward = exePath.replaceAll(r'\', '/');
  if (forward.startsWith('/AppTranslocation/') ||
      forward.contains('/AppTranslocation/') ||
      forward.startsWith('/nix/store/') ||
      forward.startsWith('/tmp/.mount_') ||
      forward.startsWith('/usr/')) {
    return true;
  }
  final segments = forward.split('/');
  return segments.contains('build');
}

PortableInstallLayout _resolveWindowsLayout(String exePath) {
  final dirPath = p.dirname(exePath);
  final icuPath = p.join(dirPath, 'data', 'icudtl.dat');
  if (FileSystemEntity.typeSync(icuPath) != FileSystemEntityType.file ||
      !_probeDirectoryWritable(dirPath)) {
    return const PortableInstallLayout(
      operatingSystem: 'windows',
      capability: SelfUpdateCapability.readOnlyOrNonPortable,
    );
  }
  return PortableInstallLayout(
    operatingSystem: 'windows',
    capability: SelfUpdateCapability.supported,
    portableRootPath: dirPath,
    lockAndCleanupDirPath: dirPath,
    stagingDirPath: p.join(dirPath, '.fterm-update'),
  );
}

PortableInstallLayout _resolveLinuxLayout(String exePath) {
  final dirPath = p.dirname(exePath);
  final hasData =
      FileSystemEntity.typeSync(p.join(dirPath, 'data')) ==
      FileSystemEntityType.directory;
  final hasLib =
      FileSystemEntity.typeSync(p.join(dirPath, 'lib')) ==
      FileSystemEntityType.directory;
  if (!hasData || !hasLib || !_probeDirectoryWritable(dirPath)) {
    return const PortableInstallLayout(
      operatingSystem: 'linux',
      capability: SelfUpdateCapability.readOnlyOrNonPortable,
    );
  }
  return PortableInstallLayout(
    operatingSystem: 'linux',
    capability: SelfUpdateCapability.supported,
    portableRootPath: dirPath,
    lockAndCleanupDirPath: dirPath,
    stagingDirPath: p.join(dirPath, '.fterm-update'),
  );
}

PortableInstallLayout _resolveMacosLayout(
  String exePath, {
  int? posixUid,
  String? stagingNonce,
}) {
  // Expected: <Parent>/<App>.app/Contents/MacOS/<Exec>
  final macosDir = p.dirname(exePath);
  final contentsDir = p.dirname(macosDir);
  final appDir = p.dirname(contentsDir);
  if (p.basename(macosDir) != 'MacOS' ||
      p.basename(contentsDir) != 'Contents' ||
      !appDir.endsWith('.app')) {
    return const PortableInstallLayout(
      operatingSystem: 'macos',
      capability: SelfUpdateCapability.readOnlyOrNonPortable,
    );
  }
  final parentDir = p.dirname(appDir);
  if (!_probeDirectoryWritable(parentDir)) {
    return const PortableInstallLayout(
      operatingSystem: 'macos',
      capability: SelfUpdateCapability.readOnlyOrNonPortable,
    );
  }
  final uid = posixUid ?? _resolvePosixUid();
  final nonce =
      stagingNonce ??
      Random.secure().nextInt(0x7FFFFFFF).toRadixString(16).padLeft(8, '0');
  final stagingPath = p.join(parentDir, '.fterm-update-$uid-$nonce');

  final bundleProbe = _probeMacosBundleModify(contentsDir);
  final capability = switch (bundleProbe) {
    _MacosProbeOutcome.ok => SelfUpdateCapability.supported,
    _MacosProbeOutcome.tccDenied =>
      SelfUpdateCapability.macosAppManagementDenied,
    _MacosProbeOutcome.readOnly => SelfUpdateCapability.readOnlyOrNonPortable,
  };
  return PortableInstallLayout(
    operatingSystem: 'macos',
    capability: capability,
    portableRootPath: appDir,
    lockAndCleanupDirPath: parentDir,
    stagingDirPath: stagingPath,
  );
}

enum _MacosProbeOutcome { ok, tccDenied, readOnly }

_MacosProbeOutcome _probeMacosBundleModify(String contentsDir) {
  final probeFile = File(
    p.join(
      contentsDir,
      '.fterm-probe-$pid-${Random.secure().nextInt(0x10000)}',
    ),
  );
  try {
    probeFile.createSync(exclusive: true);
    probeFile.deleteSync();
    return _MacosProbeOutcome.ok;
  } on FileSystemException catch (e) {
    final code = e.osError?.errorCode;
    if (code == 1 /* EPERM */ ) {
      return _MacosProbeOutcome.tccDenied;
    }
    return _MacosProbeOutcome.readOnly;
  }
}

bool _probeDirectoryWritable(String dirPath) {
  if (FileSystemEntity.typeSync(dirPath, followLinks: false) !=
      FileSystemEntityType.directory) {
    return false;
  }
  final probe = File(
    p.join(dirPath, '.fterm-probe-$pid-${Random.secure().nextInt(0x100000)}'),
  );
  try {
    probe.createSync(exclusive: true);
    probe.deleteSync();
    return true;
  } on FileSystemException {
    return false;
  }
}

int _resolvePosixUid() {
  try {
    final res = Process.runSync('id', const ['-u']);
    if (res.exitCode == 0) {
      return int.tryParse('${res.stdout}'.trim()) ?? 0;
    }
  } on Object {
    // Fallback to 0 when `id` is unavailable.
  }
  return 0;
}

/// Creates the native desktop `dart:io` [UpdateService].
UpdateService createUpdateService() => IoUpdateService.platform();

/// Invokes the headless Windows `--internal-swap-update` entrypoint when
/// requested on `dart:io`.
Future<bool> maybeRunPlatformInternalSwapUpdate(List<String> args) =>
    maybeExecuteWindowsInternalSwap(args);

/// Process runner callback signature for testable OS tool invocations (`tar`,
/// `xattr`, `codesign`, `open`, `chmod`, `icacls`).
typedef SystemProcessRunner =
    Future<ProcessResult> Function(String executable, List<String> arguments);

/// `dart:io` desktop implementation of [UpdateService].
final class IoUpdateService implements UpdateService {
  @override
  final FtermSemVer currentVersion;

  final IoUpdateRepository _repository;
  final PortableInstallLayout _layout;
  final Future<int?> Function(String dirPath) _freeDiskBytesProbe;
  final SystemProcessRunner _processRunner;
  final DetachedProcessLauncher _detachedLauncher;
  final void Function(int code) _exitFn;
  final Map<String, String> _environment;

  PortableInstanceLock? _instanceLock;
  SelfUpdateCapability _capability;
  bool _disposed = false;

  /// Creates an [IoUpdateService] with explicit seams for testing.
  IoUpdateService({
    required this.currentVersion,
    required IoUpdateRepository repository,
    required PortableInstallLayout layout,
    @visibleForTesting
    Future<int?> Function(String dirPath)? freeDiskBytesProbe,
    @visibleForTesting SystemProcessRunner? processRunner,
    @visibleForTesting DetachedProcessLauncher? detachedLauncher,
    @visibleForTesting void Function(int code)? onExit,
    @visibleForTesting Map<String, String>? environment,
  }) : _repository = repository,
       _layout = layout,
       _capability = layout.capability,
       _freeDiskBytesProbe = freeDiskBytesProbe ?? queryAvailableDiskBytes,
       _processRunner = processRunner ?? Process.run,
       _detachedLauncher = detachedLauncher ?? _defaultLaunchDetached,
       _exitFn = onExit ?? exit,
       _environment = environment ?? Platform.environment {
    final lockDir = _layout.lockAndCleanupDirPath;
    if (lockDir != null) {
      _instanceLock = PortableInstanceLock.tryAcquireShared(lockDir);
    }
  }

  /// Builds the default host [IoUpdateService].
  factory IoUpdateService.platform() {
    final version =
        FtermSemVer.tryParse(kFtermBuildVersion) ??
        FtermSemVer(0, 0, 0, prerelease: const ['dev']);
    final target = resolveHostTargetPlatform();
    final layout = resolvePortableInstallLayout();
    return IoUpdateService(
      currentVersion: version,
      repository: IoUpdateRepository(
        httpClient: IoUpdateHttpClient(),
        targetPlatform: target,
      ),
      layout: layout,
    );
  }

  static Future<void> _defaultLaunchDetached(
    String executable,
    List<String> arguments,
    String workingDirectory,
  ) async {
    await Process.start(
      executable,
      arguments,
      mode: ProcessStartMode.detached,
      workingDirectory: workingDirectory,
    );
  }

  @override
  SelfUpdateCapability get capability => _capability;

  @override
  Future<UpdateCheckOutcome> checkForUpdates({
    required bool includePrereleases,
    String? lastEtag,
    List<String> cachedTags = const [],
  }) => _repository.checkForUpdates(
    currentVersion: currentVersion,
    includePrereleases: includePrereleases,
    lastEtag: lastEtag,
    cachedTags: cachedTags,
  );

  @override
  Future<StagedUpdate> stageUpdate(
    AvailableUpdate update, {
    void Function(DownloadProgress progress)? onProgress,
  }) async {
    final asset = update.asset;
    if (asset == null) {
      throw UpdateException(
        update.unavailableAssetReason ??
            'No prebuilt update archive is available for this platform.',
      );
    }
    final portableRoot = _layout.portableRootPath;
    final lockDir = _layout.lockAndCleanupDirPath;
    final stagingDir = _layout.stagingDirPath;
    if (portableRoot == null || lockDir == null || stagingDir == null) {
      throw const UpdateException(
        'In-place updates are unavailable for this installation.',
      );
    }

    await _ensureFreeDiskHeadroom(lockDir, asset.size);
    final updateLock = PortableUpdateLock.tryAcquire(lockDir);
    if (updateLock == null) {
      throw const UpdateException(
        'Another fterm window is currently staging an update.',
      );
    }
    try {
      await _preparePrivateStagingDir(stagingDir);
      final archiveFile = File(p.join(stagingDir, asset.name));
      await _repository.httpClient.downloadToFile(
        uri: asset.browserDownloadUrl,
        destinationFile: archiveFile,
        expectedBytes: asset.size,
        onProgress: onProgress,
      );
      return await _verifyAndExtractStagedArchive(
        update: update,
        asset: asset,
        archivePath: archiveFile.path,
        stagingDir: stagingDir,
        portableRoot: portableRoot,
      );
    } catch (_) {
      await _deleteQuietly(stagingDir);
      rethrow;
    } finally {
      updateLock.release();
    }
  }

  Future<void> _ensureFreeDiskHeadroom(String dirPath, int assetSize) async {
    final freeBytes = await _freeDiskBytesProbe(dirPath);
    final requiredBytes = kRequiredFreeDiskHeadroomBytes + assetSize;
    if (freeBytes != null && freeBytes < requiredBytes) {
      final freeMb = (freeBytes / (1024 * 1024)).toStringAsFixed(0);
      throw UpdateException(
        'Insufficient disk space ($freeMb MB free; at least 250 MB required).',
      );
    }
  }

  Future<void> _preparePrivateStagingDir(String stagingDir) async {
    final existingType = await FileSystemEntity.type(
      stagingDir,
      followLinks: false,
    );
    if (existingType == FileSystemEntityType.link) {
      throw UpdateException(
        'Refusing to use symlinked update staging directory "$stagingDir".',
      );
    }
    if (existingType != FileSystemEntityType.notFound) {
      await Directory(stagingDir).delete(recursive: true);
    }
    await Directory(stagingDir).create(recursive: true);
    if (_layout.operatingSystem == 'windows') {
      await _restrictWindowsStagingAcl(stagingDir);
    } else {
      final res = await _processRunner('chmod', ['0700', stagingDir]);
      if (res.exitCode != 0) {
        throw UpdateException(
          'Failed setting 0700 permissions on "$stagingDir": ${res.stderr}',
        );
      }
    }
  }

  Future<void> _restrictWindowsStagingAcl(String stagingDir) async {
    final user = _environment['USERNAME']?.trim();
    if (user == null || user.isEmpty) return;
    final domain = _environment['USERDOMAIN']?.trim();
    final principal = (domain != null && domain.isNotEmpty)
        ? '$domain\\$user'
        : user;
    try {
      await _processRunner('icacls', [
        stagingDir,
        '/inheritance:r',
        '/grant:r',
        '$principal:(OI)(CI)F',
      ]);
    } on Object {
      // Best-effort ACL restriction when icacls is unavailable.
    }
  }

  Future<StagedUpdate> _verifyAndExtractStagedArchive({
    required AvailableUpdate update,
    required ReleaseAssetInfo asset,
    required String archivePath,
    required String stagingDir,
    required String portableRoot,
  }) async {
    final extractedDir = p.join(stagingDir, 'extracted');
    await Directory(extractedDir).create(recursive: true);

    if (_layout.operatingSystem == 'windows') {
      final expectedSize = asset.size;
      final expectedSha = asset.sha256Hex;
      final entries = await Isolate.run(() async {
        await verifyFileSizeAndSha256(
          filePath: archivePath,
          expectedSize: expectedSize,
          expectedSha256Hex: expectedSha,
        );
        return extractAndValidateWindowsZip(
          zipPath: archivePath,
          outputDirPath: extractedDir,
        );
      });
      await _deleteQuietly(archivePath);
      return StagedUpdate(
        update: update,
        stagingDirPath: stagingDir,
        stagedPayloadPath: extractedDir,
        portableRootPath: portableRoot,
        manifestEntries: entries,
      );
    }

    final expectedSize = asset.size;
    final expectedSha = asset.sha256Hex;
    await Isolate.run(() async {
      await verifyFileSizeAndSha256(
        filePath: archivePath,
        expectedSize: expectedSize,
        expectedSha256Hex: expectedSha,
      );
      await inspectTarGzStream(tarGzPath: archivePath);
    });
    await _extractUnixTarGz(archivePath, extractedDir);
    await _deleteQuietly(archivePath);

    if (_layout.operatingSystem == 'macos') {
      final stagedApp = await _verifyMacosStagedBundle(extractedDir);
      return StagedUpdate(
        update: update,
        stagingDirPath: stagingDir,
        stagedPayloadPath: stagedApp,
        portableRootPath: portableRoot,
      );
    }

    final entries = _verifyLinuxStagedBundle(extractedDir);
    return StagedUpdate(
      update: update,
      stagingDirPath: stagingDir,
      stagedPayloadPath: extractedDir,
      portableRootPath: portableRoot,
      manifestEntries: entries,
    );
  }

  Future<void> _extractUnixTarGz(
    String archivePath,
    String extractedDir,
  ) async {
    final tarBin = File('/usr/bin/tar').existsSync() ? '/usr/bin/tar' : 'tar';
    final res = await _processRunner(tarBin, [
      '-xzf',
      archivePath,
      '-C',
      extractedDir,
    ]);
    if (res.exitCode != 0) {
      throw UpdateException('tar extraction failed: ${res.stderr}');
    }
  }

  Future<String> _verifyMacosStagedBundle(String extractedDir) async {
    final stagedApp = p.join(extractedDir, 'fterm.app');
    if (await FileSystemEntity.type(stagedApp, followLinks: false) !=
        FileSystemEntityType.directory) {
      throw const UpdateException(
        'Staged macOS archive does not contain fterm.app.',
      );
    }
    await _processRunner('/usr/bin/xattr', [
      '-dr',
      'com.apple.quarantine',
      stagedApp,
    ]);
    final verify = await _processRunner('/usr/bin/codesign', [
      '--verify',
      '--deep',
      '--strict',
      stagedApp,
    ]);
    if (verify.exitCode != 0) {
      throw UpdateException(
        'Staged fterm.app failed codesign verification: ${verify.stderr}',
      );
    }
    return stagedApp;
  }

  static List<String> _verifyLinuxStagedBundle(String extractedDir) {
    final exe = p.join(extractedDir, 'fterm');
    final dataDir = p.join(extractedDir, 'data');
    final libDir = p.join(extractedDir, 'lib');
    if (FileSystemEntity.typeSync(exe, followLinks: false) !=
            FileSystemEntityType.file ||
        FileSystemEntity.typeSync(dataDir, followLinks: false) !=
            FileSystemEntityType.directory ||
        FileSystemEntity.typeSync(libDir, followLinks: false) !=
            FileSystemEntityType.directory) {
      throw const UpdateException(
        'Staged Linux archive is missing fterm, data/, or lib/.',
      );
    }
    return readOrSynthesizeBundleManifest(extractedDir);
  }

  @override
  bool hasSiblingInstances() => _instanceLock?.hasSiblingInstances() ?? false;

  @override
  bool prepareExclusiveSwapLock() {
    final lock = _instanceLock;
    if (lock == null) return true;
    return lock.tryUpgradeToExclusiveForSwap();
  }

  @override
  void cancelExclusiveSwapLock() => _instanceLock?.downgradeToShared();

  @override
  Future<void> applyStagedUpdateAndExit(
    StagedUpdate staged, {
    required bool relaunch,
    List<String> relaunchArgs = const [],
    Future<void> Function()? beforeExitTeardown,
  }) async {
    if (!prepareExclusiveSwapLock()) {
      throw const UpdateException(
        'Close other open fterm windows from this folder before restarting.',
      );
    }
    if (beforeExitTeardown != null) {
      await beforeExitTeardown();
    }
    try {
      switch (_layout.operatingSystem) {
        case 'macos':
          await performMacosInProcessSwap(
            stagedAppPath: staged.stagedPayloadPath,
            targetAppPath: staged.portableRootPath,
            relaunch: relaunch,
            relaunchArgs: relaunchArgs,
            detachedLauncher: _detachedLauncher,
          );
        case 'linux':
          await performLinuxInProcessSwap(
            stagedDirPath: staged.stagedPayloadPath,
            targetDirPath: staged.portableRootPath,
            relaunch: relaunch,
            relaunchArgs: relaunchArgs,
            detachedLauncher: _detachedLauncher,
          );
        case 'windows':
          await _spawnWindowsStagedSwapper(
            staged: staged,
            relaunch: relaunch,
            relaunchArgs: relaunchArgs,
          );
        default:
          throw const UpdateException('Unsupported desktop host OS.');
      }
    } on UpdateException catch (e) {
      if (e.isMacosPermissionDenied) {
        _capability = SelfUpdateCapability.macosAppManagementDenied;
      }
      cancelExclusiveSwapLock();
      rethrow;
    } on Object {
      cancelExclusiveSwapLock();
      rethrow;
    }

    _instanceLock?.release();
    _instanceLock = null;
    _exitFn(0);
  }

  Future<void> _spawnWindowsStagedSwapper({
    required StagedUpdate staged,
    required bool relaunch,
    required List<String> relaunchArgs,
  }) async {
    final stagedExe = p.join(staged.stagedPayloadPath, 'fterm.exe');
    final swapArgs = <String>[
      kInternalSwapUpdateFlag,
      '--wait-pid',
      '$pid',
      '--staged',
      staged.stagedPayloadPath,
      '--target',
      staged.portableRootPath,
      if (relaunch) ...[
        '--relaunch',
        p.join(staged.portableRootPath, 'fterm.exe'),
        '--',
        ...relaunchArgs,
      ],
    ];
    // Release `.fterm-instance.lock` right before spawning so `<Dir>` holds no
    // lingering lock handles if exit completes quickly.
    _instanceLock?.release();
    _instanceLock = null;
    await _detachedLauncher(stagedExe, swapArgs, Directory.systemTemp.path);
  }

  @override
  Future<void> revealStagedInFinder(StagedUpdate staged) async {
    if (_layout.operatingSystem != 'macos') return;
    await _processRunner('/usr/bin/open', ['-R', staged.stagedPayloadPath]);
  }

  @override
  Future<void> runStartupCleanup() async {
    if (_disposed || _environment.containsKey('FLUTTER_TEST')) return;
    final cleanupDir = _layout.lockAndCleanupDirPath;
    if (cleanupDir == null) return;
    await cleanupStaleUpdateArtifacts(
      lockDirPath: cleanupDir,
      cleanupParentDir: cleanupDir,
      isWindows: _layout.operatingSystem == 'windows',
    );
  }

  static Future<void> _deleteQuietly(String path) async {
    try {
      final type = await FileSystemEntity.type(path, followLinks: false);
      if (type == FileSystemEntityType.file ||
          type == FileSystemEntityType.link) {
        await File(path).delete();
      } else if (type == FileSystemEntityType.directory) {
        await Directory(path).delete(recursive: true);
      }
    } on Object {
      // Ignore best-effort cleanup failure.
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _instanceLock?.release();
    _instanceLock = null;
    _repository.httpClient.close();
  }
}
