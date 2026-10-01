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
  Int32 Function(Pointer<Utf8>, Pointer<Pointer<Utf8>>, Pointer<Pointer<Utf8>>)
>(symbol: 'execve', isLeaf: true)
external int _nativeExecve(
  Pointer<Utf8> file,
  Pointer<Pointer<Utf8>> argv,
  Pointer<Pointer<Utf8>> envp,
);

@Native<Int32 Function()>(symbol: 'getpid', isLeaf: true)
external int _nativeGetpid();

@Native<Int32 Function(Int32, Int32)>(symbol: 'kill', isLeaf: true)
external int _nativeKill(int pid, int sig);

@Native<Int32 Function()>(symbol: 'fork', isLeaf: true)
external int _nativeFork();

@Native<Int32 Function()>(symbol: 'setsid', isLeaf: true)
external int _nativeSetsid();

@Native<Int32 Function(Int32, Uint64, VarArgs<(Pointer<Void>,)>)>(
  symbol: 'ioctl',
  isLeaf: true,
)
external int _nativeIoctl(int fd, int request, Pointer<Void> argp);

@Native<Int32 Function(Int32, Int32)>(symbol: 'dup2', isLeaf: true)
external int _nativeDup2(int oldfd, int newfd);

@Native<Int32 Function(Pointer<Utf8>)>(symbol: 'chdir', isLeaf: true)
external int _nativeChdir(Pointer<Utf8> path);

@Native<Int32 Function(Int32)>(symbol: 'close', isLeaf: true)
external int _nativeClose(int fd);

Map<String, String> _buildUnixEnvironment(
  Map<String, String>? customEnvironment,
) {
  const inheritedKeys = {
    'LOGNAME',
    'USER',
    'DISPLAY',
    'LC_TYPE',
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
      final pPts = arena<Int32>();
      final name = arena<Int8>(256);

      final sz = arena<winsize>();
      sz.ref.ws_col = 80;
      sz.ref.ws_row = 20;

      if (unix.openpty(pPtm, pPts, name, nullptr, sz) != 0) {
        throw PtyException('openpty failed');
      }

      final ptm = pPtm.value;
      final pts = pPts.value;

      unix.fcntl3(ptm, consts.F_SETFD, consts.FD_CLOEXEC);
      unix.fcntl3(pts, consts.F_SETFD, consts.FD_CLOEXEC);

      final isMacOS = Platform.isMacOS;
      final nullPtr = nullptr;
      final hasWorkDir = nativeWorkDir != nullptr;

      // Eagerly resolve @Native functions BEFORE fork!
      _nativeExecve(nullPtr.cast(), nullPtr.cast(), nullPtr.cast());
      _nativeGetpid();
      _nativeKill(-1, 0);
      _nativeSetsid();
      _nativeIoctl(-1, 0, nullPtr);
      _nativeDup2(-1, -1);
      _nativeClose(-1);
      _nativeChdir(nativeExecutable);

      final pid = _nativeFork();

      if (pid == 0) {
        // Child process - strict async-signal-safe POSIX calls only
        // NO LOOPS ALLOWED (backward branches trigger safepoints and deadlock)
        _nativeSetsid();

        final tiocsctty = isMacOS ? 0x20007461 : 0x540E;
        _nativeIoctl(pts, tiocsctty, nullPtr);

        _nativeDup2(pts, 0);
        _nativeDup2(pts, 1);
        _nativeDup2(pts, 2);

        _nativeClose(ptm);
        _nativeClose(pts);

        if (hasWorkDir) {
          _nativeChdir(nativeWorkDir);
        }

        _nativeExecve(nativeExecutable, argv, env);

        _nativeKill(_nativeGetpid(), 9); // SIGKILL
      }

      unix.close(pts);

      if (pid < 0) {
        unix.close(ptm);
        throw PtyException('fork failed.');
      }

      if (raw && unix.cfmakeraw != null) {
        final termp = arena<termios>();
        if (unix.tcgetattr(ptm, termp) != -1) {
          unix.cfmakeraw!(termp);
          unix.tcsetattr(ptm, consts.TCSANOW, termp);
        }
      }

      return PtyCoreUnix._(pid, ptm);
    });
  }

  PtyCoreUnix._(this._pid, this._ptm) {
    _writeBuffer = calloc<Uint8>(_bufferSize + 1);
    _worker = PtyCoreUnixWorker(ptm: _ptm, pid: _pid);

    _finalizer.attach(this, _writeBuffer.cast(), detach: this);
    if (_ptm >= 0) {
      _closeFinalizer.attach(this, Pointer.fromAddress(_ptm), detach: this);
    }
  }

  final int _pid;
  int _ptm;
  static const _bufferSize = 81920;

  late final Pointer<Uint8> _writeBuffer;
  static final _finalizer = NativeFinalizer(calloc.nativeFree);
  static final _libc = DynamicLibrary.process();
  static final _closeFinalizer = NativeFinalizer(
    _libc.lookup<NativeFunction<Void Function(Pointer<Void>)>>('close'),
  );

  late final PtyCoreUnixWorker _worker;

  void _closePtm() {
    if (_ptm >= 0) {
      final fd = _ptm;
      _ptm = -1;
      _closeFinalizer.detach(this);
      unix.close(fd);
    }
  }

  static bool _isProcessDead(int pid) {
    if (pid <= 0) return true;
    return unix.kill(pid, 0) != 0;
  }

  @override
  PtyCoreUnixWorker get worker => _worker;

  @override
  Uint8List? read() => _worker.read();

  @override
  int? exitCodeNonBlocking() {
    final statusPointer = calloc<Int32>();
    final pid = unix.waitpid(_pid, statusPointer, consts.WNOHANG);

    final status = statusPointer.value;
    calloc.free(statusPointer);

    if (pid == 0) {
      return null;
    }
    if (pid < 0) {
      // ECHILD: VM reaped the status
      final isDead = unix.kill(_pid, 0) != 0;
      if (isDead) {
        return -1;
      }
      return null;
    }

    if ((status & 0x7F) != 0) {
      // killed by signal
      return 128 + (status & 0x7F);
    }
    return (status & 0xFF00) >> 8;
  }

  @override
  int exitCodeBlocking() => _worker.exitCodeBlocking();

  bool _killed = false;

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    if (_killed) return false;
    _killed = true;

    final sigNum = _mapSignal(signal);
    final ret = unix.kill(_pid, sigNum) == 0;
    // Explicitly send SIGHUP to force child to exit and break the blocked read()
    // because closing a file descriptor on Linux does not interrupt a blocking read.
    unix.kill(_pid, 1);
    _closePtm();
    return ret;
  }

  int _mapSignal(ProcessSignal signal) => switch (signal) {
    ProcessSignal.sigterm => 15,
    ProcessSignal.sigkill => 9,
    ProcessSignal.sighup => 1,
    ProcessSignal.sigint => 2,
    ProcessSignal.sigusr1 => 10,
    ProcessSignal.sigusr2 => 12,
    _ => 15,
  };

  @override
  void resize(int width, int height) {
    if (_ptm < 0) return;
    final sz = calloc<winsize>();
    sz.ref.ws_col = width;
    sz.ref.ws_row = height;

    final ret = unix.ioctl(_ptm, consts.TIOCSWINSZ, sz.cast<Void>());
    calloc.free(sz);

    if (ret == -1) {
      // print(_ptm);
      // print(unix.errno.value);
      unix.perror(nullptr);
    }
  }

  // @override
  // int get pid {
  //   return _pid;
  // }

  @override
  void write(List<int> data) {
    if (_ptm < 0) return;
    var offset = 0;
    while (offset < data.length) {
      final chunkLen = (data.length - offset > _bufferSize)
          ? _bufferSize
          : (data.length - offset);
      final dest = _writeBuffer.cast<Uint8>().asTypedList(chunkLen);
      if (data is Uint8List) {
        dest.setRange(0, chunkLen, data, offset);
      } else {
        for (var i = 0; i < chunkLen; i++) {
          dest[i] = data[offset + i];
        }
      }
      unix.write(_ptm, _writeBuffer.cast(), chunkLen);
      offset += chunkLen;
    }
  }
}

final class PtyCoreUnixWorker implements PtyCoreWorker {
  final int ptm;
  final int pid;
  static const _bufferSize = 81920;

  Pointer<Int8>? _buffer;
  Pointer<pollfd>? _pPollFd;

  PtyCoreUnixWorker({required this.ptm, required this.pid});

  @override
  Uint8List? read() {
    if (ptm < 0) return null;
    _buffer ??= calloc<Int8>(_bufferSize + 1);
    _pPollFd ??= calloc<pollfd>();
    final pfd = _pPollFd!;
    final buf = _buffer!;

    while (true) {
      pfd.ref.fd = ptm;
      pfd.ref.events = consts.POLLIN;
      pfd.ref.revents = 0;

      final ret = unix.poll(pfd, 1, 100);
      if (ret > 0) {
        final revents = pfd.ref.revents;
        if ((revents & consts.POLLIN) != 0) {
          final readlen = unix.read(ptm, buf.cast(), _bufferSize);
          if (readlen <= 0) {
            return null;
          }
          return Uint8List.fromList(buf.cast<Uint8>().asTypedList(readlen));
        }

        if ((revents & (consts.POLLHUP | consts.POLLERR | consts.POLLNVAL)) !=
            0) {
          return null;
        }
      } else if (ret == 0) {
        if (PtyCoreUnix._isProcessDead(pid)) {
          return null;
        }
      } else {
        if (unix.errno != null && unix.errno!.value == consts.EINTR) {
          continue;
        }
        return null;
      }
    }
  }

  @override
  int exitCodeBlocking() {
    final statusPointer = calloc<Int32>();
    final pidResult = unix.waitpid(pid, statusPointer, 0);

    final status = statusPointer.value;
    calloc.free(statusPointer);

    if (pidResult < 0) {
      // ECHILD: VM reaped it
      final isDead = unix.kill(pid, 0) != 0;
      if (isDead) {
        return -1;
      }
    }

    if ((status & 0x7F) != 0) {
      return 128 + (status & 0x7F);
    }
    return (status & 0xFF00) >> 8;
  }

  @override
  void free() {
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
