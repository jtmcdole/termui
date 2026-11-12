// ignore_for_file: public_member_api_docs

import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:pty2/src/pty_core.dart';
import 'package:pty2/src/pty_error.dart';
import 'package:pty2/src/util/unix_const.dart';
import 'package:pty2/src/util/unix_ffi.dart';

@Native<
  Int32 Function(
    Pointer<Utf8>,
    Pointer<Pointer<Utf8>>,
    Pointer<Pointer<Utf8>>,
    Pointer<Utf8>,
    Uint16,
    Uint16,
    Int32,
    Pointer<Int32>,
    Pointer<Int32>,
    Pointer<Int32>,
  )
>(symbol: 'pty2_spawn_unix')
external int _pty2SpawnUnix(
  Pointer<Utf8> executable,
  Pointer<Pointer<Utf8>> argv,
  Pointer<Pointer<Utf8>> envp,
  Pointer<Utf8> workingDir,
  int cols,
  int rows,
  int raw,
  Pointer<Int32> outPtm,
  Pointer<Int32> outStatusFd,
  Pointer<Int32> outShimPid,
);

@Native<Int32 Function(Int32)>(symbol: 'pty2_dup_cloexec')
external int _pty2DupCloexec(int fd);

@Native<IntPtr Function(Int32, Pointer<Void>, UintPtr)>(symbol: 'pty2_read')
external int _pty2Read(int fd, Pointer<Void> buf, int count);

@Native<IntPtr Function(Int32, Pointer<Void>, UintPtr)>(symbol: 'pty2_write')
external int _pty2Write(int fd, Pointer<Void> buf, int count);

@Native<Int32 Function(Pointer<Void>, UintPtr, Int32)>(symbol: 'pty2_poll')
external int _pty2Poll(Pointer<Void> fds, int nfds, int timeoutMs);

@Native<Int32 Function(Int32, Pointer<Int32>, Int32)>(symbol: 'pty2_waitpid')
external int _pty2Waitpid(int pid, Pointer<Int32> outStatus, int options);

@Native<Int32 Function(Int32, Uint16, Uint16, Uint16, Uint16)>(
  symbol: 'pty2_resize',
)
external int _pty2Resize(int fd, int cols, int rows, int xpixel, int ypixel);

@Native<Pointer<Void> Function(UintPtr, Int32, Int32, Int32, Int32)>(
  symbol: 'pty2_alloc_main_state',
)
external Pointer<Void> _pty2AllocMainState(
  int bufSize,
  int ptm,
  int statusFd,
  int shimPid,
  int shellPid,
);

@Native<Void Function(Pointer<Void>)>(symbol: 'pty2_dispose_main_state')
external void _pty2DisposeMainState(Pointer<Void> ptr);

@Native<Pointer<Uint8> Function(Pointer<Void>)>(
  symbol: 'pty2_main_state_write_buffer',
)
external Pointer<Uint8> _pty2MainStateWriteBuffer(Pointer<Void> ptr);

@Native<Int32 Function(Pointer<Void>)>(symbol: 'pty2_get_ptm', isLeaf: true)
external int _pty2GetPtm(Pointer<Void> ptr);

@Native<Void Function(Pointer<Void>)>(symbol: 'pty2_close_ptm')
external void _pty2ClosePtm(Pointer<Void> ptr);

@Native<Uint8 Function(Pointer<Void>)>(symbol: 'pty2_is_stopped', isLeaf: true)
external int _pty2IsStopped(Pointer<Void> ptr);

@Native<Int32 Function(Pointer<Void>, Int32, Pointer<Int32>)>(
  symbol: 'pty2_reap_status',
)
external int _pty2ReapStatus(
  Pointer<Void> mainState,
  int blocking,
  Pointer<Int32> outStatus,
);

@Native<Int32 Function(Pointer<Void>, Int32)>(symbol: 'pty2_kill_shell')
external int _pty2KillShell(Pointer<Void> mainState, int sig);

Map<String, String> _buildUnixEnvironment(
  Map<String, String>? customEnvironment,
) {
  const inheritedKeys = {
    'LOGNAME',
    'USER',
    'DISPLAY',
    'LC_CTYPE',
    'HOME',
    'PATH',
  };

  return {
    'TERM': 'xterm-256color',
    'LANG': 'en_US.UTF-8',
    for (final MapEntry(:key, :value) in Platform.environment.entries)
      if (inheritedKeys.contains(key)) key: value,
    ...?customEnvironment,
  };
}

String _resolveExecutablePath(String executable, String? pathEnv) {
  if (executable.contains('/')) return executable;

  final searchPath = pathEnv ?? Platform.environment['PATH'] ?? '';
  for (final dir in searchPath.split(':')) {
    if (dir.isEmpty) continue;
    final candidate = '$dir/$executable';
    if (File(candidate).existsSync()) return candidate;
  }

  return executable;
}

Pointer<Pointer<Utf8>> _allocateNativeStringArray(
  Arena arena,
  Iterable<String> strings,
) {
  final list = strings.toList(growable: false);
  final array = arena<Pointer<Utf8>>(list.length + 1);
  array[list.length] = nullptr;

  for (var i = 0; i < list.length; i++) {
    array[i] = list[i].toNativeUtf8(allocator: arena);
  }

  return array;
}

int _decodeWaitStatus(int status) {
  if ((status & 0x7F) != 0) {
    return 128 + (status & 0x7F);
  }
  return (status & 0xFF00) >> 8;
}

int? _reapExitCode(Pointer<Void> mainState, {required bool blocking}) {
  if (mainState == nullptr) return null;
  return using((arena) {
    final statusPointer = arena<Int32>();
    final ret = _pty2ReapStatus(mainState, blocking ? 1 : 0, statusPointer);
    if (ret == 0) {
      return null;
    }
    if (ret < 0) {
      return -1;
    }
    return _decodeWaitStatus(statusPointer.value);
  });
}

void _cleanupSpawnFailure({
  required Arena arena,
  required int shellPid,
  required int shimPid,
  required int mainPtm,
  required int statusFd,
  int workerPtm = -1,
}) {
  if (workerPtm >= 0) unix.close(workerPtm);
  if (mainPtm >= 0) unix.close(mainPtm);
  if (statusFd >= 0) unix.close(statusFd);
  if (shellPid > 1) {
    unix.kill(-shellPid, consts.SIGKILL);
    unix.kill(shellPid, consts.SIGKILL);
  }
  if (shimPid > 0) _pty2Waitpid(shimPid, arena<Int32>(), 0);
}

final class PtyCoreUnix implements PtyCore, Finalizable {
  factory PtyCoreUnix.start(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
    bool raw = false,
  }) {
    final effectiveEnv = _buildUnixEnvironment(environment);
    final resolvedExecutable = _resolveExecutablePath(
      executable,
      effectiveEnv['PATH'],
    );

    return using((Arena arena) {
      final nativeExecutable = resolvedExecutable.toNativeUtf8(
        allocator: arena,
      );
      final nativeWorkDir =
          workingDirectory?.toNativeUtf8(allocator: arena) ?? nullptr;

      final argv = _allocateNativeStringArray(arena, [
        executable,
        ...arguments,
      ]);
      final env = _allocateNativeStringArray(
        arena,
        effectiveEnv.entries.map((e) => '${e.key}=${e.value}'),
      );

      final pPtm = arena<Int32>();
      final pStatusFd = arena<Int32>();
      final pShimPid = arena<Int32>();
      final shellPid = _pty2SpawnUnix(
        nativeExecutable,
        argv,
        env,
        nativeWorkDir,
        80,
        20,
        raw ? 1 : 0,
        pPtm,
        pStatusFd,
        pShimPid,
      );

      if (shellPid == -2) {
        throw PtyException('openpty failed');
      }
      if (shellPid < 0) {
        throw PtyException('fork failed.');
      }

      final ptm = pPtm.value;
      final statusFd = pStatusFd.value;
      final shimPid = pShimPid.value;
      final workerPtm = _pty2DupCloexec(ptm);
      if (workerPtm < 0) {
        _cleanupSpawnFailure(
          arena: arena,
          shellPid: shellPid,
          shimPid: shimPid,
          mainPtm: ptm,
          statusFd: statusFd,
        );
        throw PtyException('dup failed');
      }

      return PtyCoreUnix._(
        shellPid: shellPid,
        shimPid: shimPid,
        mainPtm: ptm,
        workerPtm: workerPtm,
        statusFd: statusFd,
      );
    });
  }

  PtyCoreUnix._({
    required int shellPid,
    required int shimPid,
    required int mainPtm,
    required int workerPtm,
    required int statusFd,
  }) {
    final nativeMem = _pty2AllocMainState(
      _bufferSize,
      mainPtm,
      statusFd,
      shimPid,
      shellPid,
    );
    if (nativeMem == nullptr) {
      using((arena) {
        _cleanupSpawnFailure(
          arena: arena,
          shellPid: shellPid,
          shimPid: shimPid,
          mainPtm: mainPtm,
          statusFd: statusFd,
          workerPtm: workerPtm,
        );
      });
      throw PtyException('alloc failed');
    }
    _nativeMem = nativeMem;
    _writeBuffer = _pty2MainStateWriteBuffer(nativeMem);
    _worker = PtyCoreUnixWorker(
      ptm: workerPtm,
      mainStateAddress: nativeMem.address,
    );

    _finalizer.attach(this, _nativeMem, detach: this);
  }

  static const _bufferSize = 81920;

  late final Pointer<Void> _nativeMem;
  late final Pointer<Uint8> _writeBuffer;
  static final _finalizer = NativeFinalizer(
    Native.addressOf<NativeFunction<Void Function(Pointer<Void>)>>(
      _pty2DisposeMainState,
    ),
  );

  late final PtyCoreUnixWorker _worker;

  @override
  PtyCoreUnixWorker get worker => _worker;

  @override
  Uint8List? read() => _worker.read();

  @override
  void onReaderClosed() {
    _pty2ClosePtm(_nativeMem);
  }

  @override
  int? exitCodeNonBlocking() => _reapExitCode(_nativeMem, blocking: false);

  @override
  int exitCodeBlocking() => _worker.exitCodeBlocking();

  bool _killed = false;

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    _pty2ClosePtm(_nativeMem);
    if (_killed && signal != ProcessSignal.sigkill) return false;

    final sigNum = _mapSignal(signal);
    final delivered = _pty2KillShell(_nativeMem, sigNum) != 0;
    if (!delivered) {
      _killed = true;
      return false;
    }
    _killed = true;
    // Also send SIGHUP alongside closing ptm on the reader worker so
    // interactive shells that ignore SIGTERM exit immediately.
    if (sigNum != consts.SIGKILL && sigNum != consts.SIGHUP) {
      _pty2KillShell(_nativeMem, consts.SIGHUP);
    }
    return true;
  }

  int _mapSignal(ProcessSignal signal) => switch (signal) {
    ProcessSignal.sigterm => consts.SIGTERM,
    ProcessSignal.sigkill => consts.SIGKILL,
    ProcessSignal.sighup => consts.SIGHUP,
    ProcessSignal.sigint => consts.SIGINT,
    ProcessSignal.sigusr1 => consts.SIGUSR1,
    ProcessSignal.sigusr2 => consts.SIGUSR2,
    _ => consts.SIGTERM,
  };

  @override
  void resize(
    int width,
    int height, {
    int pixelWidth = 0,
    int pixelHeight = 0,
  }) {
    final ptm = _pty2GetPtm(_nativeMem);
    if (ptm < 0) return;
    _pty2Resize(
      ptm,
      width.clamp(0, 65535),
      height.clamp(0, 65535),
      pixelWidth.clamp(0, 65535),
      pixelHeight.clamp(0, 65535),
    );
  }

  @override
  void write(List<int> data) {
    if (_pty2GetPtm(_nativeMem) < 0) return;
    var offset = 0;
    while (offset < data.length) {
      final remaining = data.length - offset;
      final chunkLen = remaining > _bufferSize ? _bufferSize : remaining;
      _writeBuffer.asTypedList(chunkLen).setRange(0, chunkLen, data, offset);
      if (!_writeChunk(chunkLen)) return;
      offset += chunkLen;
    }
  }

  bool _writeChunk(int chunkLen) {
    var chunkOffset = 0;
    while (chunkOffset < chunkLen) {
      final ptm = _pty2GetPtm(_nativeMem);
      if (ptm < 0) return false;
      final written = _pty2Write(
        ptm,
        (_writeBuffer + chunkOffset).cast(),
        chunkLen - chunkOffset,
      );
      if (written > 0) {
        chunkOffset += written;
        continue;
      }
      if (written == -consts.EINTR) {
        continue;
      }
      if (written == -consts.EAGAIN) {
        _pollWritable(ptm);
        continue;
      }
      return false;
    }
    return true;
  }

  void _pollWritable(int ptm) {
    using((arena) {
      final pfd = arena<pollfd>();
      pfd.ref
        ..fd = ptm
        ..events = consts.POLLOUT
        ..revents = 0;
      _pty2Poll(pfd.cast(), 1, 100);
    });
  }
}

final class PtyCoreUnixWorker implements PtyCoreWorker {
  final int ptm;
  final int mainStateAddress;
  static const _bufferSize = 81920;

  bool _ptmClosed = false;
  Pointer<Int8>? _buffer;
  Pointer<pollfd>? _pPollFd;

  PtyCoreUnixWorker({required this.ptm, required this.mainStateAddress});

  Pointer<Void> get _mainState => Pointer<Void>.fromAddress(mainStateAddress);

  bool get _isStopped =>
      mainStateAddress == 0 || _pty2IsStopped(_mainState) != 0;

  bool get _isShellReaped =>
      mainStateAddress == 0 || _pty2ReapStatus(_mainState, 0, nullptr) != 0;

  void _closePtm() {
    if (!_ptmClosed && ptm >= 0) {
      _ptmClosed = true;
      unix.close(ptm);
    }
  }

  @override
  Uint8List? read() {
    if (_ptmClosed || ptm < 0 || _isStopped) return null;
    final buf = _buffer ??= calloc<Int8>(_bufferSize + 1);
    final pfd = _pPollFd ??= calloc<pollfd>();
    if (!_waitForReadable(pfd)) return null;

    final readlen = _pty2Read(ptm, buf.cast(), _bufferSize);
    if (readlen <= 0) return null;
    return Uint8List.fromList(buf.cast<Uint8>().asTypedList(readlen));
  }

  bool _hasTrailingInput(Pointer<pollfd> pfd) {
    pfd.ref
      ..fd = ptm
      ..events = consts.POLLIN
      ..revents = 0;
    final drainRet = _pty2Poll(pfd.cast(), 1, 0);
    return drainRet > 0 && (pfd.ref.revents & consts.POLLIN) != 0;
  }

  bool _waitForReadable(Pointer<pollfd> pfd) {
    final hangupMask = consts.POLLHUP | consts.POLLERR | consts.POLLNVAL;
    while (!_isStopped) {
      pfd.ref
        ..fd = ptm
        ..events = consts.POLLIN
        ..revents = 0;

      final ret = _pty2Poll(pfd.cast(), 1, 50);
      if (ret == -consts.EINTR) continue;
      if (ret < 0) return false;
      if (ret == 0) {
        if (!_isShellReaped) continue;
        return _hasTrailingInput(pfd);
      }

      final revents = pfd.ref.revents;
      if ((revents & consts.POLLIN) != 0) return true;
      if ((revents & hangupMask) != 0) return false;
    }
    return false;
  }

  @override
  int exitCodeBlocking() => _reapExitCode(_mainState, blocking: true) ?? -1;

  @override
  void free() {
    _closePtm();
    if (_buffer != null && _buffer != nullptr) {
      calloc.free(_buffer!);
      _buffer = null;
    }
    if (_pPollFd != null && _pPollFd != nullptr) {
      calloc.free(_pPollFd!);
      _pPollFd = null;
    }
  }
}
