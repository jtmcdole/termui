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
);

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
      final pid = _pty2SpawnUnix(
        nativeExecutable,
        argv,
        env,
        nativeWorkDir,
        80,
        20,
        raw ? 1 : 0,
        pPtm,
      );

      if (pid == -2) {
        throw PtyException('openpty failed');
      }
      if (pid < 0) {
        throw PtyException('fork failed.');
      }

      return PtyCoreUnix._(pid, pPtm.value);
    });
  }

  PtyCoreUnix._(this._pid, this._ptm) {
    _nativeMem = calloc<Uint8>(_bufferSize + 8);
    _stopFlag = _nativeMem;
    _writeBuffer = _nativeMem + 8;
    _worker = PtyCoreUnixWorker(
      ptm: _ptm,
      pid: _pid,
      stopFlagAddress: _stopFlag.address,
    );

    _finalizer.attach(this, _nativeMem.cast(), detach: this);
  }

  final int _pid;
  int _ptm;
  static const _bufferSize = 81920;

  late final Pointer<Uint8> _nativeMem;
  late final Pointer<Uint8> _stopFlag;
  late final Pointer<Uint8> _writeBuffer;
  static final _finalizer = NativeFinalizer(calloc.nativeFree);

  late final PtyCoreUnixWorker _worker;

  void _closePtm() {
    _stopFlag.value = 1;
    if (_ptm >= 0) {
      _ptm = -1;
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
        _reaped = true;
        return -1;
      }
      return null;
    }

    _reaped = true;
    if ((status & 0x7F) != 0) {
      // killed by signal
      return 128 + (status & 0x7F);
    }
    return (status & 0xFF00) >> 8;
  }

  @override
  int exitCodeBlocking() => _worker.exitCodeBlocking();

  bool _killed = false;
  bool _reaped = false;

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    _closePtm();
    if (_reaped) return false;
    if (_killed && signal != ProcessSignal.sigkill) return false;
    if (_isProcessDead(_pid)) {
      _killed = true;
      return false;
    }
    _killed = true;

    final sigNum = _mapSignal(signal);
    if (_pid > 1) {
      unix.kill(-_pid, sigNum);
    }
    final ret = unix.kill(_pid, sigNum) == 0;
    // Also send SIGHUP alongside closing ptm on the reader worker so
    // interactive shells that ignore SIGTERM exit immediately.
    if (sigNum != 9 && sigNum != 1) {
      _sendSignal(1);
    }
    return ret;
  }

  void _sendSignal(int sigNum) {
    if (_pid > 1) {
      unix.kill(-_pid, sigNum);
    }
    unix.kill(_pid, sigNum);
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
      var chunkOffset = 0;
      while (chunkOffset < chunkLen) {
        if (_ptm < 0) return;
        final written = unix.write(
          _ptm,
          (_writeBuffer + chunkOffset).cast(),
          chunkLen - chunkOffset,
        );
        if (written > 0) {
          chunkOffset += written;
        } else if (written < 0) {
          final err = unix.errno?.value ?? 0;
          if (err == consts.EINTR) {
            continue;
          }
          if (err == consts.EAGAIN) {
            final pfd = calloc<pollfd>();
            try {
              pfd.ref.fd = _ptm;
              pfd.ref.events = consts.POLLOUT;
              pfd.ref.revents = 0;
              unix.poll(pfd, 1, 100);
            } finally {
              calloc.free(pfd);
            }
            continue;
          }
          return;
        } else {
          return;
        }
      }
      offset += chunkLen;
    }
  }
}

final class PtyCoreUnixWorker implements PtyCoreWorker {
  final int ptm;
  final int pid;
  final int stopFlagAddress;
  static const _bufferSize = 81920;

  bool _ptmClosed = false;
  Pointer<Int8>? _buffer;
  Pointer<pollfd>? _pPollFd;

  PtyCoreUnixWorker({
    required this.ptm,
    required this.pid,
    this.stopFlagAddress = 0,
  });

  bool get _isStopped =>
      stopFlagAddress != 0 &&
      Pointer<Uint8>.fromAddress(stopFlagAddress).value != 0;

  void _closePtm() {
    if (!_ptmClosed && ptm >= 0) {
      _ptmClosed = true;
      unix.close(ptm);
    }
  }

  @override
  Uint8List? read() {
    if (_ptmClosed || ptm < 0 || _isStopped) return null;
    _buffer ??= calloc<Int8>(_bufferSize + 1);
    _pPollFd ??= calloc<pollfd>();
    final pfd = _pPollFd!;
    final buf = _buffer!;

    while (!_isStopped) {
      pfd.ref.fd = ptm;
      pfd.ref.events = consts.POLLIN;
      pfd.ref.revents = 0;

      final ret = unix.poll(pfd, 1, 50);
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
    return null;
  }

  @override
  int exitCodeBlocking() {
    final statusPointer = calloc<Int32>();
    var pidResult = -1;
    while (true) {
      pidResult = unix.waitpid(pid, statusPointer, 0);
      if (pidResult < 0 &&
          unix.errno != null &&
          unix.errno!.value == consts.EINTR) {
        continue;
      }
      break;
    }

    final status = statusPointer.value;
    calloc.free(statusPointer);

    if (pidResult < 0) {
      // ECHILD: VM reaped it
      final isDead = unix.kill(pid, 0) != 0;
      if (isDead) {
        return -1;
      }
      return -1;
    }

    if ((status & 0x7F) != 0) {
      return 128 + (status & 0x7F);
    }
    return (status & 0xFF00) >> 8;
  }

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
