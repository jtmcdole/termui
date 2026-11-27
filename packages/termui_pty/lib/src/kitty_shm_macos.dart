import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'kitty_medium.dart';

const int _oRdOnly = 0;
const int _enoent = 2;
const int _protRead = 1;
const int _mapShared = 1;
const int _darwinStatBytes = 144;
const int _darwinStatSizeInt64Index = 96 ~/ 8;
const int _macosMaxShmNameBytes = 30;
final RegExp _pathSeparatorRegex = RegExp(r'[/\\]');

typedef _ShmOpenNative =
    Int32 Function(Pointer<Uint8>, Int32, VarArgs<(Uint32,)>);
typedef _ShmOpenDart = int Function(Pointer<Uint8>, int, int);
typedef _ShmUnlinkNative = Int32 Function(Pointer<Uint8>);
typedef _ShmUnlinkDart = int Function(Pointer<Uint8>);
typedef _FstatNative = Int32 Function(Int32, Pointer<Uint8>);
typedef _FstatDart = int Function(int, Pointer<Uint8>);
typedef _MmapNative =
    Pointer<Uint8> Function(Pointer<Void>, Size, Int32, Int32, Int32, Int64);
typedef _MmapDart =
    Pointer<Uint8> Function(Pointer<Void>, int, int, int, int, int);
typedef _MunmapNative = Int32 Function(Pointer<Uint8>, Size);
typedef _MunmapDart = int Function(Pointer<Uint8>, int);
typedef _CloseNative = Int32 Function(Int32);
typedef _CloseDart = int Function(int);
typedef _MallocNative = Pointer<Uint8> Function(Size);
typedef _MallocDart = Pointer<Uint8> Function(int);
typedef _FreeNative = Void Function(Pointer<Uint8>);
typedef _FreeDart = void Function(Pointer<Uint8>);
typedef _ErrnoNative = Pointer<Int32> Function();
typedef _ErrnoDart = Pointer<Int32> Function();
typedef _GetPageSizeNative = Int32 Function();
typedef _GetPageSizeDart = int Function();

final class _MacosShmBindings {
  final _ShmOpenDart shmOpen;
  final _ShmUnlinkDart shmUnlink;
  final _FstatDart fstat;
  final _MmapDart mmap;
  final _MunmapDart munmap;
  final _CloseDart close;
  final _MallocDart malloc;
  final _FreeDart free;
  final _ErrnoDart errnoPtr;
  final _GetPageSizeDart getpagesize;

  _MacosShmBindings(DynamicLibrary lib)
    : shmOpen = lib.lookupFunction<_ShmOpenNative, _ShmOpenDart>(
        'shm_open',
        isLeaf: true,
      ),
      shmUnlink = lib.lookupFunction<_ShmUnlinkNative, _ShmUnlinkDart>(
        'shm_unlink',
        isLeaf: true,
      ),
      fstat = lib.lookupFunction<_FstatNative, _FstatDart>(
        Abi.current() == Abi.macosX64 ? 'fstat\$INODE64' : 'fstat',
        isLeaf: true,
      ),
      mmap = lib.lookupFunction<_MmapNative, _MmapDart>('mmap', isLeaf: true),
      munmap = lib.lookupFunction<_MunmapNative, _MunmapDart>(
        'munmap',
        isLeaf: true,
      ),
      close = lib.lookupFunction<_CloseNative, _CloseDart>(
        'close',
        isLeaf: true,
      ),
      malloc = lib.lookupFunction<_MallocNative, _MallocDart>(
        'malloc',
        isLeaf: true,
      ),
      free = lib.lookupFunction<_FreeNative, _FreeDart>('free', isLeaf: true),
      errnoPtr = lib.lookupFunction<_ErrnoNative, _ErrnoDart>(
        '__error',
        isLeaf: true,
      ),
      getpagesize = lib.lookupFunction<_GetPageSizeNative, _GetPageSizeDart>(
        'getpagesize',
        isLeaf: true,
      );
}

_MacosShmBindings? _cachedBindings;

_MacosShmBindings? _loadMacosBindings() {
  if (!Platform.isMacOS) return null;
  if (_cachedBindings case final existing?) return existing;
  try {
    final lib = DynamicLibrary.open('/usr/lib/libSystem.dylib');
    return _cachedBindings = _MacosShmBindings(lib);
  } on ArgumentError {
    try {
      return _cachedBindings = _MacosShmBindings(DynamicLibrary.process());
    } on ArgumentError {
      return null;
    }
  }
}

/// Validates and normalizes a POSIX shared-memory object name for macOS
/// (`shm_open` requires a leading `/` and at most 30 bytes before NUL).
String? normalizeMacosShmName(String decoded) {
  final clean = decoded.startsWith('/') ? decoded.substring(1) : decoded;
  if (clean.isEmpty ||
      clean.contains(_pathSeparatorRegex) ||
      clean.contains('\x00') ||
      clean == '.' ||
      clean == '..') {
    return null;
  }
  final normalized = '/$clean';
  if (utf8.encode(normalized).length > _macosMaxShmNameBytes) return null;
  return normalized;
}

int? _readMacosFdSize(_MacosShmBindings lib, int fd) {
  final statBuf = lib.malloc(_darwinStatBytes);
  if (statBuf == nullptr) return null;
  try {
    if (lib.fstat(fd, statBuf) != 0) return null;
    return statBuf.cast<Int64>()[_darwinStatSizeInt64Index];
  } finally {
    lib.free(statBuf);
  }
}

/// Reads `[offset, offset + readLen)` via `mmap` because XNU's `DTYPE_PSXSHM`
/// rejects `read(2)`/`pread(2)` with `ENOTSUP`. Uses a page-aligned mapping
/// offset so large `O=` values never map the preceding prefix.
KittyMediumReadResult _mmapReadSlice(
  _MacosShmBindings lib,
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

  final pageSize = math.max(1, lib.getpagesize());
  final alignedOffset = offset - (offset % pageSize);
  final delta = offset - alignedOffset;
  final mapLen = delta + readLen;
  final ptr = lib.mmap(
    nullptr,
    mapLen,
    _protRead,
    _mapShared,
    fd,
    alignedOffset,
  );
  if (ptr == nullptr || ptr.address == -1) {
    return const KittyMediumReadInvalid();
  }
  try {
    final out = Uint8List(readLen);
    out.setRange(0, readLen, ptr.asTypedList(mapLen), delta);
    return KittyMediumReadOk(out);
  } finally {
    lib.munmap(ptr, mapLen);
  }
}

/// Reads a macOS POSIX shared-memory object (`t=s`) via `shm_open`, `fstat`,
/// and `mmap`, optionally unlinking it with `shm_unlink` when [unlink] is
/// `true` and the read succeeds.
KittyMediumReadResult readMacosPosixShm(
  String decodedName, {
  required int maxBytes,
  int offset = 0,
  int? size,
  bool unlink = true,
}) {
  if (offset < 0 || maxBytes < 0 || (size != null && size < 0)) {
    return const KittyMediumReadInvalid();
  }
  final lib = _loadMacosBindings();
  if (lib == null) return const KittyMediumReadUnsupported();

  final normalized = normalizeMacosShmName(decodedName);
  if (normalized == null) return const KittyMediumReadInvalid();

  final nameBytes = utf8.encode(normalized);
  final namePtr = lib.malloc(nameBytes.length + 1);
  if (namePtr == nullptr) return const KittyMediumReadInvalid();
  try {
    namePtr.asTypedList(nameBytes.length).setAll(0, nameBytes);
    namePtr[nameBytes.length] = 0;

    final fd = lib.shmOpen(namePtr, _oRdOnly, 0);
    if (fd < 0) {
      return lib.errnoPtr().value == _enoent
          ? const KittyMediumReadNotFound()
          : const KittyMediumReadInvalid();
    }
    try {
      final fileLen = _readMacosFdSize(lib, fd);
      if (fileLen == null) return const KittyMediumReadInvalid();
      final result = _mmapReadSlice(
        lib,
        fd,
        fileLen: fileLen,
        maxBytes: maxBytes,
        offset: offset,
        size: size,
      );
      if (unlink && result is KittyMediumReadOk) {
        lib.shmUnlink(namePtr);
      }
      return result;
    } finally {
      lib.close(fd);
    }
  } finally {
    lib.free(namePtr);
  }
}
