import 'dart:io';

import 'package:path/path.dart' as p;

/// File name held with `FileLock.shared` by every running `fterm` instance in a
/// portable directory (or `<Parent>` on macOS).
const String kFtermInstanceLockFileName = '.fterm-instance.lock';

/// File name held with `FileLock.exclusive` during archive staging and `.fterm-bak`
/// cleanup.
const String kFtermUpdateLockFileName = '.fterm-update.lock';

/// Coordinates multi-instance lock ownership on `.fterm-instance.lock`.
///
/// Maintains a single open [RandomAccessFile] handle for the workspace lifetime
/// so POSIX `fcntl(F_SETLK)` locks are never inadvertently dropped by closing a
/// duplicate file descriptor for the same inode.
final class PortableInstanceLock {
  final RandomAccessFile _raf;
  final bool _isWindows;
  bool _closed = false;
  bool _holdingExclusive = false;

  PortableInstanceLock._(this._raf, {required this._isWindows});

  /// Opens `.fterm-instance.lock` in [lockDirectoryPath] and acquires a
  /// non-blocking shared lock (`FileLock.shared`), returning `null` if another
  /// process currently holds an exclusive swap lock or the directory is read-only.
  static PortableInstanceLock? tryAcquireShared(
    String lockDirectoryPath, {
    bool? isWindows,
  }) {
    final lockPath = p.join(lockDirectoryPath, kFtermInstanceLockFileName);
    if (FileSystemEntity.typeSync(lockPath, followLinks: false) ==
        FileSystemEntityType.link) {
      return null;
    }
    RandomAccessFile? raf;
    try {
      raf = File(lockPath).openSync(mode: FileMode.append);
      raf.lockSync(FileLock.shared);
      return PortableInstanceLock._(
        raf,
        isWindows: isWindows ?? Platform.isWindows,
      );
    } on FileSystemException {
      try {
        raf?.closeSync();
      } on FileSystemException {
        // Ignore close error after failed open/lock.
      }
      return null;
    }
  }

  /// Whether this instance currently holds the exclusive pre-swap lock.
  bool get isHoldingExclusive => !_closed && _holdingExclusive;

  /// Probes whether any sibling `fterm` process holds `.fterm-instance.lock`
  /// while keeping this process's shared lock intact afterwards.
  bool hasSiblingInstances() {
    if (_closed) return false;
    if (_holdingExclusive) return false;
    if (!_tryUpgradeToExclusiveInternal()) {
      return true;
    }
    _downgradeToSharedInternal();
    return false;
  }

  /// Attempts to upgrade this process's `.fterm-instance.lock` to
  /// `FileLock.exclusive` before shutting down for an update swap.
  ///
  /// Returns `true` when zero sibling instances hold the lock, or `false`
  /// (leaving `FileLock.shared` active) when another instance is open.
  bool tryUpgradeToExclusiveForSwap() {
    if (_closed) return false;
    if (_holdingExclusive) return true;
    return _tryUpgradeToExclusiveInternal();
  }

  /// Downgrades back to `FileLock.shared` if a swap is aborted after
  /// [tryUpgradeToExclusiveForSwap].
  void downgradeToShared() {
    if (_closed || !_holdingExclusive) return;
    _downgradeToSharedInternal();
  }

  bool _tryUpgradeToExclusiveInternal() {
    if (_isWindows) {
      // Win32 LockFileEx forbids overlapping locks on the same HANDLE, so
      // release our shared lock and immediately request exclusive.
      _raf.unlockSync();
      try {
        _raf.lockSync(FileLock.exclusive);
        _holdingExclusive = true;
        return true;
      } on FileSystemException {
        _reacquireSharedBestEffort();
        return false;
      }
    }
    // POSIX fcntl(F_SETLK) atomically upgrades F_RDLCK -> F_WRLCK in-place on
    // the same descriptor without dropping the existing lock on EAGAIN.
    try {
      _raf.lockSync(FileLock.exclusive);
      _holdingExclusive = true;
      return true;
    } on FileSystemException {
      return false;
    }
  }

  void _downgradeToSharedInternal() {
    if (_isWindows) {
      _raf.unlockSync();
    }
    _raf.lockSync(FileLock.shared);
    _holdingExclusive = false;
  }

  void _reacquireSharedBestEffort() {
    try {
      _raf.lockSync(FileLock.shared);
    } on FileSystemException {
      // Best-effort recovery if sibling promoted simultaneously.
    }
  }

  /// Releases the OS file lock and closes the backing handle.
  void release() {
    if (_closed) return;
    _closed = true;
    _holdingExclusive = false;
    try {
      _raf.unlockSync();
    } on FileSystemException {
      // Closing the handle also releases OS locks.
    }
    try {
      _raf.closeSync();
    } on FileSystemException {
      // Ignore close errors during exit.
    }
  }
}

/// Exclusive non-blocking lock on `.fterm-update.lock` serializing archive
/// staging and post-update `.fterm-bak` cleanup across processes.
final class PortableUpdateLock {
  final RandomAccessFile _raf;
  bool _closed = false;

  PortableUpdateLock._(this._raf);

  /// Acquires `FileLock.exclusive` on `.fterm-update.lock` inside
  /// [lockDirectoryPath], returning `null` if busy or symlinked.
  static PortableUpdateLock? tryAcquire(String lockDirectoryPath) {
    final lockPath = p.join(lockDirectoryPath, kFtermUpdateLockFileName);
    if (FileSystemEntity.typeSync(lockPath, followLinks: false) ==
        FileSystemEntityType.link) {
      return null;
    }
    RandomAccessFile? raf;
    try {
      raf = File(lockPath).openSync(mode: FileMode.append);
      raf.lockSync(FileLock.exclusive);
      return PortableUpdateLock._(raf);
    } on FileSystemException {
      try {
        raf?.closeSync();
      } on FileSystemException {
        // Ignore close failure.
      }
      return null;
    }
  }

  /// Unlocks and closes `.fterm-update.lock`.
  void release() {
    if (_closed) return;
    _closed = true;
    try {
      _raf.unlockSync();
    } on FileSystemException {
      // Ignore unlock failure before close.
    }
    try {
      _raf.closeSync();
    } on FileSystemException {
      // Ignore close failure.
    }
  }
}
