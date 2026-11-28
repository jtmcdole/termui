import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'kitty_medium.dart';

const int _oRdOnly = 0;
const int _enoent = 2;
const int _eintr = 4;
const int _sIfmt = 0xF000;
const int _sIfreg = 0x8000;

typedef _OpenNative = Int32 Function(Pointer<Uint8>, Int32, VarArgs<(Uint32,)>);
typedef _OpenDart = int Function(Pointer<Uint8>, int, int);
typedef _OpenAtNative =
    Int32 Function(Int32, Pointer<Uint8>, Int32, VarArgs<(Uint32,)>);
typedef _OpenAtDart = int Function(int, Pointer<Uint8>, int, int);
typedef _FstatNative = Int32 Function(Int32, Pointer<Uint8>);
typedef _FstatDart = int Function(int, Pointer<Uint8>);
typedef _FxstatNative = Int32 Function(Int32, Int32, Pointer<Uint8>);
typedef _FxstatDart = int Function(int, int, Pointer<Uint8>);
typedef _FstatAtNative =
    Int32 Function(Int32, Pointer<Uint8>, Pointer<Uint8>, Int32);
typedef _FstatAtDart = int Function(int, Pointer<Uint8>, Pointer<Uint8>, int);
typedef _FxstatAtNative =
    Int32 Function(Int32, Int32, Pointer<Uint8>, Pointer<Uint8>, Int32);
typedef _FxstatAtDart =
    int Function(int, int, Pointer<Uint8>, Pointer<Uint8>, int);
typedef _PreadNative = IntPtr Function(Int32, Pointer<Uint8>, Size, Int64);
typedef _PreadDart = int Function(int, Pointer<Uint8>, int, int);
typedef _UnlinkAtNative = Int32 Function(Int32, Pointer<Uint8>, Int32);
typedef _UnlinkAtDart = int Function(int, Pointer<Uint8>, int);
typedef _CloseNative = Int32 Function(Int32);
typedef _CloseDart = int Function(int);
typedef _GetEuidNative = Uint32 Function();
typedef _GetEuidDart = int Function();
typedef _MallocNative = Pointer<Uint8> Function(Size);
typedef _MallocDart = Pointer<Uint8> Function(int);
typedef _FreeNative = Void Function(Pointer<Uint8>);
typedef _FreeDart = void Function(Pointer<Uint8>);
typedef _ErrnoNative = Pointer<Int32> Function();
typedef _ErrnoDart = Pointer<Int32> Function();

final class _PosixAbi {
  final int oNonblock;
  final int oDirectory;
  final int oNofollow;
  final int oCloexec;
  final int atSymlinkNofollow;
  final int statBytes;
  final int devOffset;
  final bool devIs32Bit;
  final int inoOffset;
  final int modeOffset;
  final bool modeIs16Bit;
  final int uidOffset;
  final int sizeOffset;
  final int linuxStatVer;

  const _PosixAbi({
    required this.oNonblock,
    required this.oDirectory,
    required this.oNofollow,
    required this.oCloexec,
    required this.atSymlinkNofollow,
    required this.statBytes,
    required this.devOffset,
    required this.devIs32Bit,
    required this.inoOffset,
    required this.modeOffset,
    required this.modeIs16Bit,
    required this.uidOffset,
    required this.sizeOffset,
    required this.linuxStatVer,
  });

  static _PosixAbi? current() => switch (Abi.current()) {
    Abi.linuxX64 => const _PosixAbi(
      oNonblock: 0x0800,
      oDirectory: 0x10000,
      oNofollow: 0x20000,
      oCloexec: 0x80000,
      atSymlinkNofollow: 0x0100,
      statBytes: 144,
      devOffset: 0,
      devIs32Bit: false,
      inoOffset: 8,
      modeOffset: 24,
      modeIs16Bit: false,
      uidOffset: 28,
      sizeOffset: 48,
      linuxStatVer: 1,
    ),
    Abi.linuxArm64 => const _PosixAbi(
      oNonblock: 0x0800,
      oDirectory: 0x4000,
      oNofollow: 0x8000,
      oCloexec: 0x80000,
      atSymlinkNofollow: 0x0100,
      statBytes: 128,
      devOffset: 0,
      devIs32Bit: false,
      inoOffset: 8,
      modeOffset: 16,
      modeIs16Bit: false,
      uidOffset: 24,
      sizeOffset: 48,
      linuxStatVer: 0,
    ),
    Abi.macosX64 || Abi.macosArm64 => const _PosixAbi(
      oNonblock: 0x0004,
      oDirectory: 0x100000,
      oNofollow: 0x0100,
      oCloexec: 0x1000000,
      atSymlinkNofollow: 0x0020,
      statBytes: 144,
      devOffset: 0,
      devIs32Bit: true,
      inoOffset: 8,
      modeOffset: 4,
      modeIs16Bit: true,
      uidOffset: 16,
      sizeOffset: 96,
      linuxStatVer: 0,
    ),
    _ => null,
  };
}

typedef _PosixStatInfo = ({int dev, int ino, int mode, int uid, int size});

final class _PosixFileBindings {
  final _PosixAbi abi;
  final _OpenDart open;
  final _OpenAtDart openat;
  final int Function(int fd, Pointer<Uint8> buf) fstat;
  final int Function(
    int dirFd,
    Pointer<Uint8> name,
    Pointer<Uint8> buf,
    int flags,
  )
  fstatat;
  final _PreadDart pread;
  final _UnlinkAtDart unlinkat;
  final _CloseDart close;
  final _GetEuidDart geteuid;
  final _MallocDart malloc;
  final _FreeDart free;
  final _ErrnoDart errnoPtr;

  _PosixFileBindings._({
    required this.abi,
    required this.open,
    required this.openat,
    required this.fstat,
    required this.fstatat,
    required this.pread,
    required this.unlinkat,
    required this.close,
    required this.geteuid,
    required this.malloc,
    required this.free,
    required this.errnoPtr,
  });

  factory _PosixFileBindings(DynamicLibrary lib, _PosixAbi abi) {
    final isMacosX64 = Abi.current() == Abi.macosX64;
    final fstatFn = _resolveFstat(lib, abi, isMacosX64: isMacosX64);
    final fstatatFn = _resolveFstatAt(lib, abi, isMacosX64: isMacosX64);
    final errnoSym = Platform.isMacOS ? '__error' : '__errno_location';

    return _PosixFileBindings._(
      abi: abi,
      open: lib.lookupFunction<_OpenNative, _OpenDart>('open', isLeaf: true),
      openat: lib.lookupFunction<_OpenAtNative, _OpenAtDart>(
        'openat',
        isLeaf: true,
      ),
      fstat: fstatFn,
      fstatat: fstatatFn,
      pread: lib.lookupFunction<_PreadNative, _PreadDart>(
        'pread',
        isLeaf: true,
      ),
      unlinkat: lib.lookupFunction<_UnlinkAtNative, _UnlinkAtDart>(
        'unlinkat',
        isLeaf: true,
      ),
      close: lib.lookupFunction<_CloseNative, _CloseDart>(
        'close',
        isLeaf: true,
      ),
      geteuid: lib.lookupFunction<_GetEuidNative, _GetEuidDart>(
        'geteuid',
        isLeaf: true,
      ),
      malloc: lib.lookupFunction<_MallocNative, _MallocDart>(
        'malloc',
        isLeaf: true,
      ),
      free: lib.lookupFunction<_FreeNative, _FreeDart>('free', isLeaf: true),
      errnoPtr: lib.lookupFunction<_ErrnoNative, _ErrnoDart>(
        errnoSym,
        isLeaf: true,
      ),
    );
  }

  static int Function(int, Pointer<Uint8>) _resolveFstat(
    DynamicLibrary lib,
    _PosixAbi abi, {
    required bool isMacosX64,
  }) {
    final directSym = isMacosX64 ? r'fstat$INODE64' : 'fstat';
    if (lib.providesSymbol(directSym)) {
      return lib.lookupFunction<_FstatNative, _FstatDart>(
        directSym,
        isLeaf: true,
      );
    }
    final fxstat = lib.lookupFunction<_FxstatNative, _FxstatDart>(
      '__fxstat',
      isLeaf: true,
    );
    return (fd, buf) => fxstat(abi.linuxStatVer, fd, buf);
  }

  static int Function(int, Pointer<Uint8>, Pointer<Uint8>, int) _resolveFstatAt(
    DynamicLibrary lib,
    _PosixAbi abi, {
    required bool isMacosX64,
  }) {
    final directSym = isMacosX64 ? r'fstatat$INODE64' : 'fstatat';
    if (lib.providesSymbol(directSym)) {
      return lib.lookupFunction<_FstatAtNative, _FstatAtDart>(
        directSym,
        isLeaf: true,
      );
    }
    final fxstatat = lib.lookupFunction<_FxstatAtNative, _FxstatAtDart>(
      '__fxstatat',
      isLeaf: true,
    );
    return (dirFd, name, buf, flags) =>
        fxstatat(abi.linuxStatVer, dirFd, name, buf, flags);
  }
}

_PosixFileBindings? _cachedPosixBindings;

_PosixFileBindings? _loadPosixBindings() {
  if (_cachedPosixBindings case final existing?) return existing;
  final abi = _PosixAbi.current();
  if (abi == null) return null;
  final candidates = Platform.isMacOS
      ? const ['/usr/lib/libSystem.dylib']
      : const ['libc.so.6'];
  for (final name in candidates) {
    try {
      return _cachedPosixBindings = _PosixFileBindings(
        DynamicLibrary.open(name),
        abi,
      );
    } on ArgumentError {
      // Fall through to process lookup.
    }
  }
  try {
    return _cachedPosixBindings = _PosixFileBindings(
      DynamicLibrary.process(),
      abi,
    );
  } on ArgumentError {
    return null;
  }
}

Pointer<Uint8> _allocCString(_PosixFileBindings lib, String value) {
  final bytes = utf8.encode(value);
  final ptr = lib.malloc(bytes.length + 1);
  if (ptr == nullptr) return nullptr;
  ptr.asTypedList(bytes.length).setAll(0, bytes);
  ptr[bytes.length] = 0;
  return ptr;
}

_PosixStatInfo _decodeStatBuf(_PosixAbi abi, Pointer<Uint8> buf) {
  final view = buf.asTypedList(abi.statBytes).buffer.asByteData();
  final dev = abi.devIs32Bit
      ? view.getUint32(abi.devOffset, Endian.host)
      : view.getInt64(abi.devOffset, Endian.host);
  final ino = view.getInt64(abi.inoOffset, Endian.host);
  final mode = abi.modeIs16Bit
      ? view.getUint16(abi.modeOffset, Endian.host)
      : view.getUint32(abi.modeOffset, Endian.host);
  final uid = view.getUint32(abi.uidOffset, Endian.host);
  final size = view.getInt64(abi.sizeOffset, Endian.host);
  return (dev: dev, ino: ino, mode: mode, uid: uid, size: size);
}

_PosixStatInfo? _statFd(_PosixFileBindings lib, int fd) {
  final buf = lib.malloc(lib.abi.statBytes);
  if (buf == nullptr) return null;
  try {
    if (lib.fstat(fd, buf) != 0) return null;
    return _decodeStatBuf(lib.abi, buf);
  } finally {
    lib.free(buf);
  }
}

_PosixStatInfo? _statAtNoFollow(
  _PosixFileBindings lib,
  int dirFd,
  Pointer<Uint8> leafPtr,
) {
  final buf = lib.malloc(lib.abi.statBytes);
  if (buf == nullptr) return null;
  try {
    if (lib.fstatat(dirFd, leafPtr, buf, lib.abi.atSymlinkNofollow) != 0) {
      return null;
    }
    return _decodeStatBuf(lib.abi, buf);
  } finally {
    lib.free(buf);
  }
}

int _openDirectoryWalk(
  _PosixFileBindings lib,
  String rootDir,
  List<String> relativeSegments,
) {
  final rootPtr = _allocCString(lib, rootDir);
  if (rootPtr == nullptr) return -1;
  int dirFd;
  try {
    dirFd = lib.open(
      rootPtr,
      _oRdOnly | lib.abi.oDirectory | lib.abi.oCloexec,
      0,
    );
  } finally {
    lib.free(rootPtr);
  }
  if (dirFd < 0) return -1;

  for (final segment in relativeSegments) {
    final segPtr = _allocCString(lib, segment);
    if (segPtr == nullptr) {
      lib.close(dirFd);
      return -1;
    }
    final int nextFd;
    try {
      nextFd = lib.openat(
        dirFd,
        segPtr,
        _oRdOnly | lib.abi.oDirectory | lib.abi.oNofollow | lib.abi.oCloexec,
        0,
      );
    } finally {
      lib.free(segPtr);
    }
    lib.close(dirFd);
    if (nextFd < 0) return -1;
    dirFd = nextFd;
  }
  return dirFd;
}

KittyMediumReadResult _preadSlice(
  _PosixFileBindings lib,
  int fd, {
  required int fileLen,
  required int maxBytes,
  required int offset,
  required int? size,
}) {
  if (fileLen < 0 || offset > fileLen) return const KittyMediumReadInvalid();
  final available = fileLen - offset;
  final effectiveSize = (size != null && size > 0) ? size : available;
  final readLen = math.min(effectiveSize, available);
  if (readLen > maxBytes) return const KittyMediumReadTooLarge();
  if (readLen == 0) return KittyMediumReadOk(Uint8List(0));

  final nativeBuf = lib.malloc(readLen);
  if (nativeBuf == nullptr) return const KittyMediumReadInvalid();
  try {
    var totalRead = 0;
    while (totalRead < readLen) {
      final chunk = lib.pread(
        fd,
        Pointer<Uint8>.fromAddress(nativeBuf.address + totalRead),
        readLen - totalRead,
        offset + totalRead,
      );
      if (chunk == 0) break;
      if (chunk < 0) {
        if (lib.errnoPtr().value == _eintr) continue;
        return const KittyMediumReadInvalid();
      }
      totalRead += chunk;
    }
    final out = Uint8List(totalRead);
    out.setRange(0, totalRead, nativeBuf.asTypedList(totalRead));
    return KittyMediumReadOk(out);
  } finally {
    lib.free(nativeBuf);
  }
}

void _unlinkIfSameInode(
  _PosixFileBindings lib,
  int dirFd,
  Pointer<Uint8> leafPtr,
  _PosixStatInfo expected,
) {
  final current = _statAtNoFollow(lib, dirFd, leafPtr);
  if (current != null &&
      current.dev == expected.dev &&
      current.ino == expected.ino) {
    lib.unlinkat(dirFd, leafPtr, 0);
  }
}

KittyMediumReadResult _readValidatedPosixFd(
  _PosixFileBindings lib, {
  required int dirFd,
  required int fileFd,
  required Pointer<Uint8> leafPtr,
  required int maxBytes,
  required int offset,
  required int? size,
  required bool unlink,
  required bool Function(Uint8List bytes)? shouldUnlink,
}) {
  final stat = _statFd(lib, fileFd);
  if (stat == null ||
      (stat.mode & _sIfmt) != _sIfreg ||
      stat.uid != lib.geteuid()) {
    return const KittyMediumReadInvalid();
  }
  final result = _preadSlice(
    lib,
    fileFd,
    fileLen: stat.size,
    maxBytes: maxBytes,
    offset: offset,
    size: size,
  );
  if (unlink &&
      result is KittyMediumReadOk &&
      (shouldUnlink == null || shouldUnlink(result.bytes))) {
    _unlinkIfSameInode(lib, dirFd, leafPtr, stat);
  }
  return result;
}

/// Atomically opens, validates, reads, and optionally unlinks a Kitty Graphics
/// Protocol file on Linux/macOS without TOCTOU symlink or FIFO races.
///
/// Walks [relativeSegments] beneath canonical [rootDir] using
/// `openat(O_DIRECTORY | O_NOFOLLOW)`, opens [leafName] with
/// `O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC`, verifies `S_ISREG` and
/// `st_uid == geteuid()` on the open descriptor via `fstat`, reads via `pread`,
/// and verifies matching `(st_dev, st_ino)` before calling `unlinkat`.
KittyMediumReadResult readPosixKittyFile({
  required String rootDir,
  required List<String> relativeSegments,
  required String leafName,
  required int maxBytes,
  int offset = 0,
  int? size,
  bool unlink = true,
  bool Function(Uint8List bytes)? shouldUnlink,
}) {
  final lib = _loadPosixBindings();
  if (lib == null) return const KittyMediumReadUnsupported();

  final dirFd = _openDirectoryWalk(lib, rootDir, relativeSegments);
  if (dirFd < 0) {
    return lib.errnoPtr().value == _enoent
        ? const KittyMediumReadNotFound()
        : const KittyMediumReadInvalid();
  }

  final leafPtr = _allocCString(lib, leafName);
  if (leafPtr == nullptr) {
    lib.close(dirFd);
    return const KittyMediumReadInvalid();
  }
  try {
    final fileFd = lib.openat(
      dirFd,
      leafPtr,
      _oRdOnly | lib.abi.oNofollow | lib.abi.oNonblock | lib.abi.oCloexec,
      0,
    );
    if (fileFd < 0) {
      return lib.errnoPtr().value == _enoent
          ? const KittyMediumReadNotFound()
          : const KittyMediumReadInvalid();
    }
    try {
      return _readValidatedPosixFd(
        lib,
        dirFd: dirFd,
        fileFd: fileFd,
        leafPtr: leafPtr,
        maxBytes: maxBytes,
        offset: offset,
        size: size,
        unlink: unlink,
        shouldUnlink: shouldUnlink,
      );
    } finally {
      lib.close(fileFd);
    }
  } finally {
    lib.free(leafPtr);
    lib.close(dirFd);
  }
}

/// Safely opens and reads a local regular file (`t=f`) on Linux/macOS without
/// ever unlinking the target.
///
/// Opens [path] with `O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC`, verifies
/// `S_ISREG`, `st_uid == geteuid()`, and `0 <= st_size <= maxBytes` via `fstat`
/// on the open descriptor, and reads bytes via `pread`.
KittyMediumReadResult readRegularFileSafe({
  required String path,
  required int maxBytes,
  int offset = 0,
  int? size,
}) {
  final lib = _loadPosixBindings();
  if (lib == null) return const KittyMediumReadUnsupported();

  final pathPtr = _allocCString(lib, path);
  if (pathPtr == nullptr) return const KittyMediumReadInvalid();
  final int fileFd;
  try {
    fileFd = lib.open(
      pathPtr,
      _oRdOnly | lib.abi.oNofollow | lib.abi.oNonblock | lib.abi.oCloexec,
      0,
    );
  } finally {
    lib.free(pathPtr);
  }
  if (fileFd < 0) {
    return lib.errnoPtr().value == _enoent
        ? const KittyMediumReadNotFound()
        : const KittyMediumReadInvalid();
  }
  try {
    final stat = _statFd(lib, fileFd);
    if (stat == null ||
        (stat.mode & _sIfmt) != _sIfreg ||
        stat.uid != lib.geteuid() ||
        stat.size < 0) {
      return const KittyMediumReadInvalid();
    }
    if (stat.size > maxBytes) {
      return const KittyMediumReadTooLarge();
    }
    return _preadSlice(
      lib,
      fileFd,
      fileLen: stat.size,
      maxBytes: maxBytes,
      offset: offset,
      size: size,
    );
  } finally {
    lib.close(fileFd);
  }
}
