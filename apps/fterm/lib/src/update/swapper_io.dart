import 'dart:async';
import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;

import 'archive_validator_io.dart';
import 'manifest_utils.dart';
import 'portable_lock_io.dart';
import 'update_models.dart';

/// Hidden CLI flag handled at the top of `main()` when `staged\fterm.exe`
/// runs the post-exit Windows file swap headlessly.
const String kInternalSwapUpdateFlag = '--internal-swap-update';

/// Default parent exit wait budget (15 seconds) before aborting a Windows swap.
const int kDefaultParentExitWaitMs = 15000;

/// Callback signature for launching a detached process after a swap.
typedef DetachedProcessLauncher = Future<void> Function(
  String executable,
  List<String> arguments,
  String workingDirectory,
);

Future<void> _defaultDetachedLauncher(
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

/// Parses `--internal-swap-update` arguments passed to `staged\fterm.exe`.
final class WindowsSwapCliArgs {
  /// Optional parent process ID to await via `SYNCHRONIZE` before swapping.
  final int? waitPid;

  /// Staged extracted directory (`<Dir>\.fterm-update\extracted`).
  final String stagedDir;

  /// Target portable installation directory (`<Dir>`).
  final String targetDir;

  /// Optional executable to relaunch after swapping (`<Dir>\fterm.exe`).
  final String? relaunchExe;

  /// Forwarded CLI arguments passed after `--` to [relaunchExe].
  final List<String> forwardedArgs;

  /// Creates parsed [WindowsSwapCliArgs].
  WindowsSwapCliArgs({
    required this.waitPid,
    required this.stagedDir,
    required this.targetDir,
    this.relaunchExe,
    List<String> forwardedArgs = const [],
  }) : forwardedArgs = forwardedArgs.isEmpty
           ? const []
           : List<String>.unmodifiable(forwardedArgs);

  /// Parses [args] (starting with [kInternalSwapUpdateFlag]), returning `null`
  /// if required options are missing or malformed.
  static WindowsSwapCliArgs? tryParse(List<String> args) {
    if (args.isEmpty || args.first != kInternalSwapUpdateFlag) return null;
    final sepIndex = args.indexOf('--', 1);
    final optionEnd = sepIndex >= 0 ? sepIndex : args.length;
    final forwarded = sepIndex >= 0
        ? args.sublist(sepIndex + 1)
        : const <String>[];
    if ((optionEnd - 1).isOdd) return null;

    final parsedMap = _collectFlagPairs(args, 1, optionEnd);
    if (parsedMap == null) return null;

    final stagedDir = parsedMap['--staged'];
    final targetDir = parsedMap['--target'];
    if (stagedDir == null || targetDir == null) return null;

    final waitPid = _parseOptionalPositivePid(parsedMap['--wait-pid']);
    if (parsedMap.containsKey('--wait-pid') && waitPid == null) return null;

    return WindowsSwapCliArgs(
      waitPid: waitPid,
      stagedDir: stagedDir,
      targetDir: targetDir,
      relaunchExe: parsedMap['--relaunch'],
      forwardedArgs: forwarded,
    );
  }

  static const Set<String> _recognizedFlags = {
    '--wait-pid',
    '--staged',
    '--target',
    '--relaunch',
  };

  static Map<String, String>? _collectFlagPairs(
    List<String> args,
    int start,
    int end,
  ) {
    final out = <String, String>{};
    for (var i = start; i < end; i += 2) {
      final flag = args[i];
      final value = args[i + 1];
      if (!_recognizedFlags.contains(flag) || value.isEmpty) return null;
      out[flag] = value;
    }
    return out;
  }

  static int? _parseOptionalPositivePid(String? raw) {
    if (raw == null) return null;
    final parsed = int.tryParse(raw);
    return (parsed != null && parsed > 0) ? parsed : null;
  }
}

typedef _OpenProcessNative = ffi.IntPtr Function(
  ffi.Uint32 desiredAccess,
  ffi.Int32 inheritHandle,
  ffi.Uint32 processId,
);
typedef _OpenProcessDart = int Function(
  int desiredAccess,
  int inheritHandle,
  int processId,
);
typedef _WaitForSingleObjectNative = ffi.Uint32 Function(
  ffi.IntPtr handle,
  ffi.Uint32 milliseconds,
);
typedef _WaitForSingleObjectDart = int Function(int handle, int milliseconds);
typedef _CloseHandleNative = ffi.Int32 Function(ffi.IntPtr handle);
typedef _CloseHandleDart = int Function(int handle);

/// Waits up to [timeoutMs] for Win32 process [targetPid] to exit using
/// `OpenProcess(SYNCHRONIZE)` and `WaitForSingleObject`.
///
/// Returns `true` if [targetPid] already exited (`OpenProcess == 0`) or signaled
/// within [timeoutMs], or `false` on `WAIT_TIMEOUT` / `WAIT_FAILED`.
bool waitForWin32ProcessExit(int targetPid, int timeoutMs) {
  const synchronizeAccess = 0x00100000;
  const waitObject0 = 0x00000000;
  final kernel32 = ffi.DynamicLibrary.open('kernel32.dll');
  final openProcess = kernel32
      .lookupFunction<_OpenProcessNative, _OpenProcessDart>('OpenProcess');
  final waitSingle = kernel32
      .lookupFunction<_WaitForSingleObjectNative, _WaitForSingleObjectDart>(
        'WaitForSingleObject',
      );
  final closeHandle = kernel32
      .lookupFunction<_CloseHandleNative, _CloseHandleDart>('CloseHandle');

  final handle = openProcess(synchronizeAccess, 0, targetPid);
  if (handle == 0) {
    return true;
  }
  final result = waitSingle(handle, timeoutMs);
  closeHandle(handle);
  return result == waitObject0;
}

/// Queries free bytes available to the calling user on the volume containing
/// [directoryPath] using Win32 `GetDiskFreeSpaceExW` or POSIX `df -Pk`.
Future<int?> queryAvailableDiskBytes(String directoryPath) async {
  if (Platform.isWindows) {
    return _queryWindowsFreeDiskBytes(directoryPath);
  }
  return _queryPosixFreeDiskBytes(directoryPath);
}

typedef _GetDiskFreeSpaceExWNative = ffi.Int32 Function(
  ffi.Pointer<Utf16> directoryName,
  ffi.Pointer<ffi.Uint64> freeBytesAvailableToCaller,
  ffi.Pointer<ffi.Uint64> totalNumberOfBytes,
  ffi.Pointer<ffi.Uint64> totalNumberOfFreeBytes,
);
typedef _GetDiskFreeSpaceExWDart = int Function(
  ffi.Pointer<Utf16> directoryName,
  ffi.Pointer<ffi.Uint64> freeBytesAvailableToCaller,
  ffi.Pointer<ffi.Uint64> totalNumberOfBytes,
  ffi.Pointer<ffi.Uint64> totalNumberOfFreeBytes,
);

int? _queryWindowsFreeDiskBytes(String directoryPath) {
  final kernel32 = ffi.DynamicLibrary.open('kernel32.dll');
  final getFreeSpace = kernel32
      .lookupFunction<_GetDiskFreeSpaceExWNative, _GetDiskFreeSpaceExWDart>(
        'GetDiskFreeSpaceExW',
      );
  final pathPtr = directoryPath.toNativeUtf16();
  final freePtr = calloc<ffi.Uint64>();
  try {
    final ok = getFreeSpace(pathPtr, freePtr, ffi.nullptr, ffi.nullptr);
    return ok != 0 ? freePtr.value : null;
  } finally {
    calloc.free(pathPtr);
    calloc.free(freePtr);
  }
}

Future<int?> _queryPosixFreeDiskBytes(String directoryPath) async {
  try {
    final res = await Process.run('df', ['-Pk', directoryPath]);
    if (res.exitCode != 0) return null;
    final lines = '${res.stdout}'
        .split('\n')
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .toList();
    if (lines.length < 2) return null;
    final cols = lines.last.split(RegExp(r'\s+'));
    if (cols.length < 4) return null;
    final availKb = int.tryParse(cols[3]);
    return availKb == null ? null : availKb * 1024;
  } on Object {
    return null;
  }
}

/// Runs the headless Windows `--internal-swap-update` swapper when [args]
/// starts with [kInternalSwapUpdateFlag].
///
/// Returns `false` immediately for normal `fterm` launches.
Future<bool> maybeExecuteWindowsInternalSwap(
  List<String> args, {
  void Function(int code)? onExit,
  bool Function(int pid, int timeoutMs)? waitForProcessExit,
  DetachedProcessLauncher? detachedLauncher,
  int waitTimeoutMs = kDefaultParentExitWaitMs,
  int retryAttempts = 40,
  Duration retryDelay = const Duration(milliseconds: 250),
  bool pinTempWorkingDirectory = true,
}) async {
  if (args.isEmpty || args.first != kInternalSwapUpdateFlag) return false;
  final exitFn = onExit ?? exit;
  if (pinTempWorkingDirectory) {
    try {
      Directory.current = Directory.systemTemp;
    } on FileSystemException {
      // Best-effort CWD pin to %TEMP%.
    }
  }
  final parsed = WindowsSwapCliArgs.tryParse(args);
  if (parsed == null) {
    exitFn(64);
    return true;
  }
  final code = await _executeWindowsSwapFlow(
    parsed,
    waitForProcessExit: waitForProcessExit ?? waitForWin32ProcessExit,
    detachedLauncher: detachedLauncher ?? _defaultDetachedLauncher,
    waitTimeoutMs: waitTimeoutMs,
    retryAttempts: retryAttempts,
    retryDelay: retryDelay,
  );
  exitFn(code);
  return true;
}

Future<int> _executeWindowsSwapFlow(
  WindowsSwapCliArgs opts, {
  required bool Function(int pid, int timeoutMs) waitForProcessExit,
  required DetachedProcessLauncher detachedLauncher,
  required int waitTimeoutMs,
  required int retryAttempts,
  required Duration retryDelay,
}) async {
  if (opts.waitPid case final pid?
      when !waitForProcessExit(pid, waitTimeoutMs)) {
    return 1;
  }
  final List<String> unionEntries;
  try {
    unionEntries = mergeUpdateManifests(
      existing: _readOptionalManifest(opts.targetDir),
      incoming: readOrSynthesizeBundleManifest(opts.stagedDir),
    );
  } on Object {
    return 1;
  }

  if (!_stageWindowsNewCopies(opts.stagedDir, opts.targetDir, unionEntries)) {
    _deleteWindowsNewCopiesQuietly(opts.targetDir, unionEntries);
    return 1;
  }

  final completed = await _swapWindowsNewIntoTarget(
    targetDir: opts.targetDir,
    entries: unionEntries,
    retryAttempts: retryAttempts,
    retryDelay: retryDelay,
  );
  if (completed == null) {
    _deleteWindowsNewCopiesQuietly(opts.targetDir, unionEntries);
    return 1;
  }

  if (opts.relaunchExe case final exePath?) {
    try {
      await detachedLauncher(exePath, opts.forwardedArgs, opts.targetDir);
    } on Object {
      await _rollbackWindowsCompleted(
        opts.targetDir,
        completed,
        retryAttempts: retryAttempts,
        retryDelay: retryDelay,
      );
      return 1;
    }
  }
  return 0;
}

List<String> _readOptionalManifest(String dirPath) {
  final file = File(p.join(dirPath, kFtermManifestFileName));
  if (FileSystemEntity.typeSync(file.path, followLinks: false) !=
      FileSystemEntityType.file) {
    return const [];
  }
  try {
    return parseManifestJson(file.readAsStringSync());
  } on Object {
    return const [];
  }
}

bool _stageWindowsNewCopies(
  String stagedDir,
  String targetDir,
  List<String> entries,
) {
  try {
    for (final rel in entries) {
      final stagedPath = _joinRelPath(stagedDir, rel);
      final newPath = '${_joinRelPath(targetDir, rel)}.fterm-new';
      _deleteEntitySyncIfPresent(newPath);
      if (_entityExistsNoFollow(stagedPath)) {
        Directory(p.dirname(newPath)).createSync(recursive: true);
        _copyEntityRecursiveSync(stagedPath, newPath);
      }
    }
    return true;
  } on Object {
    return false;
  }
}

void _deleteWindowsNewCopiesQuietly(String targetDir, List<String> entries) {
  for (final rel in entries) {
    try {
      _deleteEntitySyncIfPresent('${_joinRelPath(targetDir, rel)}.fterm-new');
    } on Object {
      // Best-effort cleanup of abandoned .fterm-new staging entry.
    }
  }
}

final class _SwappedEntry {
  final String relPath;
  final bool hadTarget;
  final bool placedNew;

  const _SwappedEntry({
    required this.relPath,
    required this.hadTarget,
    required this.placedNew,
  });
}

Future<List<_SwappedEntry>?> _swapWindowsNewIntoTarget({
  required String targetDir,
  required List<String> entries,
  required int retryAttempts,
  required Duration retryDelay,
}) async {
  final completed = <_SwappedEntry>[];
  for (final rel in entries) {
    final targetPath = _joinRelPath(targetDir, rel);
    final bakPath = '$targetPath.fterm-bak';
    final newPath = '$targetPath.fterm-new';

    if (!_cleanStaleBackup(bakPath)) {
      await _rollbackWindowsCompleted(
        targetDir,
        completed,
        retryAttempts: retryAttempts,
        retryDelay: retryDelay,
      );
      return null;
    }
    final hadTarget = _entityExistsNoFollow(targetPath);
    final hasNew = _entityExistsNoFollow(newPath);
    if (hadTarget &&
        !await _renameWithRetry(
          targetPath,
          bakPath,
          retryAttempts: retryAttempts,
          retryDelay: retryDelay,
        )) {
      await _rollbackWindowsCompleted(
        targetDir,
        completed,
        retryAttempts: retryAttempts,
        retryDelay: retryDelay,
      );
      return null;
    }
    if (hasNew &&
        !await _renameWithRetry(
          newPath,
          targetPath,
          retryAttempts: retryAttempts,
          retryDelay: retryDelay,
        )) {
      if (hadTarget) {
        await _renameWithRetry(
          bakPath,
          targetPath,
          retryAttempts: retryAttempts,
          retryDelay: retryDelay,
        );
      }
      await _rollbackWindowsCompleted(
        targetDir,
        completed,
        retryAttempts: retryAttempts,
        retryDelay: retryDelay,
      );
      return null;
    }
    completed.add(
      _SwappedEntry(relPath: rel, hadTarget: hadTarget, placedNew: hasNew),
    );
  }
  return completed;
}

Future<void> _rollbackWindowsCompleted(
  String targetDir,
  List<_SwappedEntry> completed, {
  required int retryAttempts,
  required Duration retryDelay,
}) async {
  for (final step in completed.reversed) {
    final targetPath = _joinRelPath(targetDir, step.relPath);
    final bakPath = '$targetPath.fterm-bak';
    if (step.placedNew && _entityExistsNoFollow(targetPath)) {
      try {
        _deleteEntitySyncIfPresent(targetPath);
      } on Object {
        // Best-effort removal before restoring .fterm-bak.
      }
    }
    if (step.hadTarget && _entityExistsNoFollow(bakPath)) {
      await _renameWithRetry(
        bakPath,
        targetPath,
        retryAttempts: retryAttempts,
        retryDelay: retryDelay,
      );
    }
  }
}

bool _cleanStaleBackup(String bakPath) {
  try {
    _deleteEntitySyncIfPresent(bakPath);
    return true;
  } on Object {
    return false;
  }
}

Future<bool> _renameWithRetry(
  String fromPath,
  String toPath, {
  required int retryAttempts,
  required Duration retryDelay,
}) async {
  final attempts = retryAttempts < 1 ? 1 : retryAttempts;
  for (var i = 0; i < attempts; i++) {
    try {
      _renameEntitySync(fromPath, toPath);
      return true;
    } on FileSystemException {
      if (i + 1 < attempts) {
        await Future<void>.delayed(retryDelay);
      }
    }
  }
  return false;
}

/// Performs an in-process pure-Dart macOS `.app` bundle swap and optional
/// `/usr/bin/open -n` relaunch, rolling back `.fterm-bak` on failure.
///
/// Throws [UpdateException] (`isMacosPermissionDenied: true` on `EPERM`/`EACCES`)
/// while the calling `fterm` process is still alive.
Future<void> performMacosInProcessSwap({
  required String stagedAppPath,
  required String targetAppPath,
  required bool relaunch,
  List<String> relaunchArgs = const [],
  DetachedProcessLauncher? detachedLauncher,
}) async {
  final bakPath = '$targetAppPath.fterm-bak';
  try {
    _deleteEntitySyncIfPresent(bakPath);
    Directory(targetAppPath).renameSync(bakPath);
  } on FileSystemException catch (e) {
    throw _wrapMacosSwapException('Failed backing up $targetAppPath', e);
  }

  try {
    Directory(stagedAppPath).renameSync(targetAppPath);
  } on FileSystemException catch (e) {
    _restoreMacosBackupQuietly(bakPath, targetAppPath);
    throw _wrapMacosSwapException('Failed moving staged app into place', e);
  }

  if (!relaunch) return;
  final launcher = detachedLauncher ?? _defaultDetachedLauncher;
  try {
    await launcher('/usr/bin/open', <String>[
      '-n',
      targetAppPath,
      if (relaunchArgs.isNotEmpty) ...['--args', ...relaunchArgs],
    ], Directory.systemTemp.path);
  } on Object catch (e) {
    _rollbackMacosPlacedAppQuietly(
      stagedAppPath: stagedAppPath,
      targetAppPath: targetAppPath,
      bakPath: bakPath,
    );
    throw UpdateException('Failed relaunching updated macOS bundle: $e');
  }
}

UpdateException _wrapMacosSwapException(
  String prefix,
  FileSystemException error,
) {
  final code = error.osError?.errorCode;
  final isPermission = code == 1 /* EPERM */ || code == 13 /* EACCES */;
  if (isPermission) {
    return const UpdateException(
      'macOS blocked modifying fterm.app (App Management permission required). '
      'Reveal the staged app in Finder to drag it into Applications.',
      isMacosPermissionDenied: true,
    );
  }
  return UpdateException('$prefix: ${error.message}');
}

void _restoreMacosBackupQuietly(String bakPath, String targetAppPath) {
  try {
    if (_entityExistsNoFollow(bakPath) &&
        !_entityExistsNoFollow(targetAppPath)) {
      Directory(bakPath).renameSync(targetAppPath);
    }
  } on Object {
    // Best-effort restore.
  }
}

void _rollbackMacosPlacedAppQuietly({
  required String stagedAppPath,
  required String targetAppPath,
  required String bakPath,
}) {
  try {
    if (_entityExistsNoFollow(targetAppPath)) {
      Directory(targetAppPath).renameSync(stagedAppPath);
    }
    if (_entityExistsNoFollow(bakPath)) {
      Directory(bakPath).renameSync(targetAppPath);
    }
  } on Object {
    // Best-effort rollback after failed relaunch.
  }
}

/// Performs an in-process pure-Dart Linux portable directory swap across the
/// union of existing and staged `.fterm-files.json` manifests, rolling back all
/// `.fterm-bak` entries on failure.
Future<void> performLinuxInProcessSwap({
  required String stagedDirPath,
  required String targetDirPath,
  required bool relaunch,
  List<String> relaunchArgs = const [],
  DetachedProcessLauncher? detachedLauncher,
}) async {
  final entries = mergeUpdateManifests(
    existing: _readOptionalManifest(targetDirPath),
    incoming: readOrSynthesizeBundleManifest(stagedDirPath),
  );
  final completed = <_SwappedEntry>[];
  try {
    for (final rel in entries) {
      completed.add(_swapSinglePosixEntry(stagedDirPath, targetDirPath, rel));
    }
  } on Object catch (e) {
    _rollbackPosixCompleted(stagedDirPath, targetDirPath, completed);
    throw UpdateException('Failed swapping Linux portable bundle: $e');
  }

  if (!relaunch) return;
  final launcher = detachedLauncher ?? _defaultDetachedLauncher;
  try {
    await launcher(p.join(targetDirPath, 'fterm'), relaunchArgs, targetDirPath);
  } on Object catch (e) {
    _rollbackPosixCompleted(stagedDirPath, targetDirPath, completed);
    throw UpdateException('Failed relaunching updated Linux binary: $e');
  }
}

_SwappedEntry _swapSinglePosixEntry(
  String stagedDirPath,
  String targetDirPath,
  String rel,
) {
  final targetPath = _joinRelPath(targetDirPath, rel);
  final bakPath = '$targetPath.fterm-bak';
  final stagedPath = _joinRelPath(stagedDirPath, rel);

  _deleteEntitySyncIfPresent(bakPath);
  final hadTarget = _entityExistsNoFollow(targetPath);
  final hasStaged = _entityExistsNoFollow(stagedPath);
  Directory(p.dirname(targetPath)).createSync(recursive: true);
  if (hadTarget) {
    _renameEntitySync(targetPath, bakPath);
  }
  try {
    if (hasStaged) {
      _renameEntitySync(stagedPath, targetPath);
    }
  } catch (_) {
    if (hadTarget && _entityExistsNoFollow(bakPath)) {
      _renameEntitySync(bakPath, targetPath);
    }
    rethrow;
  }
  return _SwappedEntry(
    relPath: rel,
    hadTarget: hadTarget,
    placedNew: hasStaged,
  );
}

void _rollbackPosixCompleted(
  String stagedDirPath,
  String targetDirPath,
  List<_SwappedEntry> completed,
) {
  for (final step in completed.reversed) {
    final targetPath = _joinRelPath(targetDirPath, step.relPath);
    final bakPath = '$targetPath.fterm-bak';
    final stagedPath = _joinRelPath(stagedDirPath, step.relPath);
    try {
      if (step.placedNew && _entityExistsNoFollow(targetPath)) {
        _renameEntitySync(targetPath, stagedPath);
      }
      if (step.hadTarget && _entityExistsNoFollow(bakPath)) {
        _renameEntitySync(bakPath, targetPath);
      }
    } on Object {
      // Continue rolling back remaining entries.
    }
  }
}

/// Cleans leftover `*.fterm-bak`, `*.fterm-new`, and `.fterm-update*` trees in
/// [cleanupParentDir] inside a background isolate while holding
/// `.fterm-update.lock` (`FileLock.exclusive`).
Future<void> cleanupStaleUpdateArtifacts({
  required String lockDirPath,
  required String cleanupParentDir,
  bool isWindows = false,
  int windowsRetryCount = 12,
  Duration windowsRetryDelay = const Duration(milliseconds: 150),
}) async {
  final lock = PortableUpdateLock.tryAcquire(lockDirPath);
  if (lock == null) return;
  try {
    await Isolate.run(
      () => _deleteStaleArtifactsSync(
        cleanupParentDir: cleanupParentDir,
        isWindows: isWindows,
        windowsRetryCount: windowsRetryCount,
        windowsRetryDelay: windowsRetryDelay,
      ),
    );
  } on Object {
    // Best-effort post-frame cleanup.
  } finally {
    lock.release();
  }
}

void _deleteStaleArtifactsSync({
  required String cleanupParentDir,
  required bool isWindows,
  required int windowsRetryCount,
  required Duration windowsRetryDelay,
}) {
  final dir = Directory(cleanupParentDir);
  if (!dir.existsSync()) return;
  for (final entity in dir.listSync(followLinks: false)) {
    final name = p.basename(entity.path);
    if (!_isStaleUpdateArtifactName(name)) continue;
    _deleteArtifactWithPlatformRetry(
      entity.path,
      isWindows: isWindows,
      windowsRetryCount: windowsRetryCount,
      windowsRetryDelay: windowsRetryDelay,
    );
  }
}

bool _isStaleUpdateArtifactName(String name) =>
    (name.startsWith('.fterm-update') && name != kFtermUpdateLockFileName) ||
    name.endsWith('.fterm-bak') ||
    name.endsWith('.fterm-new');

void _deleteArtifactWithPlatformRetry(
  String targetPath, {
  required bool isWindows,
  required int windowsRetryCount,
  required Duration windowsRetryDelay,
}) {
  if (!isWindows && !Platform.isWindows) {
    Process.runSync('chmod', ['-R', 'u+w', targetPath]);
    try {
      _deleteEntitySyncIfPresent(targetPath);
    } on Object {
      // Ignore best-effort cleanup error.
    }
    return;
  }
  final attempts = windowsRetryCount < 1 ? 1 : windowsRetryCount;
  for (var i = 0; i < attempts; i++) {
    try {
      _deleteEntitySyncIfPresent(targetPath);
      return;
    } on FileSystemException {
      if (i + 1 < attempts) {
        sleep(windowsRetryDelay);
      }
    }
  }
}

String _joinRelPath(String rootDir, String relSlashPath) =>
    p.joinAll([rootDir, ...relSlashPath.split('/')]);

bool _entityExistsNoFollow(String path) =>
    FileSystemEntity.typeSync(path, followLinks: false) !=
    FileSystemEntityType.notFound;

void _renameEntitySync(String fromPath, String toPath) {
  switch (FileSystemEntity.typeSync(fromPath, followLinks: false)) {
    case FileSystemEntityType.file:
      File(fromPath).renameSync(toPath);
    case FileSystemEntityType.directory:
      Directory(fromPath).renameSync(toPath);
    case FileSystemEntityType.link:
      Link(fromPath).renameSync(toPath);
    case FileSystemEntityType.notFound:
      throw FileSystemException('Source path not found', fromPath);
    default:
      File(fromPath).renameSync(toPath);
  }
}

void _deleteEntitySyncIfPresent(String path) {
  switch (FileSystemEntity.typeSync(path, followLinks: false)) {
    case FileSystemEntityType.notFound:
      return;
    case FileSystemEntityType.file:
      File(path).deleteSync();
    case FileSystemEntityType.link:
      Link(path).deleteSync();
    case FileSystemEntityType.directory:
      Directory(path).deleteSync(recursive: true);
    default:
      File(path).deleteSync();
  }
}

void _copyEntityRecursiveSync(String srcPath, String dstPath) {
  switch (FileSystemEntity.typeSync(srcPath, followLinks: false)) {
    case FileSystemEntityType.file:
      File(srcPath).copySync(dstPath);
    case FileSystemEntityType.directory:
      Directory(dstPath).createSync(recursive: true);
      for (final child in Directory(srcPath).listSync(followLinks: false)) {
        _copyEntityRecursiveSync(
          child.path,
          p.join(dstPath, p.basename(child.path)),
        );
      }
    case FileSystemEntityType.link:
      Link(dstPath).createSync(Link(srcPath).targetSync());
    default:
      throw FileSystemException('Unsupported entity type during copy', srcPath);
  }
}
