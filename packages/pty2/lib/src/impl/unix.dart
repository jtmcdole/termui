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

class PtyCoreUnix implements PtyCore, Finalizable {
  factory PtyCoreUnix.start(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
    bool raw = false,
  }) {
    var effectiveEnv = <String, String>{};

    effectiveEnv['TERM'] = 'xterm-256color';
    // Without this, tools like "vi" produce sequences that are not UTF-8 friendly
    effectiveEnv['LANG'] = 'en_US.UTF-8';

    var envValuesToCopy = [
      'LOGNAME',
      'USER',
      'DISPLAY',
      'LC_TYPE',
      'HOME',
      'PATH',
    ];

    for (var entry in Platform.environment.entries) {
      if (envValuesToCopy.contains(entry.key)) {
        effectiveEnv[entry.key] = entry.value;
      }
    }

    if (environment != null) {
      for (var entry in environment.entries) {
        effectiveEnv[entry.key] = entry.value;
      }
    }

    var resolvedExecutable = executable;
    if (!resolvedExecutable.contains('/')) {
      final pathEnv =
          effectiveEnv['PATH'] ?? Platform.environment['PATH'] ?? '';
      for (final dir in pathEnv.split(':')) {
        if (dir.isEmpty) continue;
        final testPath = '$dir/$executable';
        if (File(testPath).existsSync()) {
          resolvedExecutable = testPath;
          break;
        }
      }
    }

    return using((Arena arena) {
      final nativeExecutable = resolvedExecutable.toNativeUtf8(
        allocator: arena,
      );
      final nativeWorkDir =
          workingDirectory?.toNativeUtf8(allocator: arena) ?? nullptr;

      final argv = arena<Pointer<Utf8>>(arguments.length + 2);
      (argv + 0).value = executable.toNativeUtf8(allocator: arena);
      (argv + arguments.length + 1).value = nullptr;
      for (var i = 0; i < arguments.length; i++) {
        (argv + i + 1).value = arguments[i].toNativeUtf8(allocator: arena);
      }

      final env = arena<Pointer<Utf8>>(effectiveEnv.length + 1);
      (env + effectiveEnv.length).value = nullptr;
      var cnt = 0;
      for (var entry in effectiveEnv.entries) {
        final envVal = '${entry.key}=${entry.value}';
        (env + cnt).value = envVal.toNativeUtf8(allocator: arena);
        cnt++;
      }

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

      // sz is already initialized above

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
      _nativeChdir(
        nativeExecutable,
      ); // safe, just returns error or changes to same

      final pid = _nativeFork();

      if (pid == 0) {
        // Child process - strict async-signal-safe POSIX calls only
        // NO LOOPS ALLOWED (backward branches trigger safepoints and deadlock)

        // 1. setsid()
        _nativeSetsid();

        // 2. ioctl()
        final tiocsctty = isMacOS ? 0x20007461 : 0x540E;
        _nativeIoctl(pts, tiocsctty, nullPtr);

        // 3. dup2()
        _nativeDup2(pts, 0);
        _nativeDup2(pts, 1);
        _nativeDup2(pts, 2);

        // 4. close FDs explicitly (no loop)
        _nativeClose(ptm);
        _nativeClose(pts);

        if (hasWorkDir) {
          _nativeChdir(nativeWorkDir);
        }

        _nativeExecve(nativeExecutable, argv, env);

        // Exiting safely without deadlocks if execve fails
        _nativeKill(_nativeGetpid(), 9); // SIGKILL
      }

      unix.close(pts);

      if (pid < 0) {
        unix.close(ptm);
        throw PtyException('fork failed.');
      } else {
        if (raw && unix.cfmakeraw != null) {
          final termp = arena<termios>();
          if (unix.tcgetattr(ptm, termp) != -1) {
            unix.cfmakeraw!(termp);
            unix.tcsetattr(ptm, consts.TCSANOW, termp);
          }
        }

        return PtyCoreUnix._(pid, ptm);
      }
    });
  }

  PtyCoreUnix._(this._pid, this._ptm) {
    _writeBuffer = calloc<Uint8>(_bufferSize + 1);
    final buffer = calloc<Int8>(_bufferSize + 1);
    _worker = PtyCoreUnixWorker(
      ptm: _ptm,
      pid: _pid,
      buffer: buffer,
      bufferSize: _bufferSize,
    );

    _closeFinalizer.attach(this, Pointer.fromAddress(_ptm), detach: this);
    _finalizer.attach(this, _writeBuffer.cast(), detach: this);
  }

  final int _pid;
  final int _ptm;
  static const _bufferSize = 81920;

  late final Pointer<Uint8> _writeBuffer;
  static final _finalizer = NativeFinalizer(calloc.nativeFree);

  static final _libc = DynamicLibrary.process();
  static final _closeFinalizer = NativeFinalizer(
    _libc.lookup<NativeFunction<Void Function(Pointer<Void>)>>('close'),
  );

  late final PtyCoreUnixWorker _worker;

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

    _closeFinalizer.detach(this);
    final sigNum = _mapSignal(signal);
    final ret = unix.kill(_pid, sigNum) == 0;
    // Explicitly send SIGHUP to force child to exit and break the blocked read()
    // because closing a file descriptor on Linux does not interrupt a blocking read.
    unix.kill(_pid, 1);
    unix.close(_ptm);
    return ret;
  }

  int _mapSignal(ProcessSignal signal) {
    if (signal == ProcessSignal.sigterm) return 15;
    if (signal == ProcessSignal.sigkill) return 9;
    if (signal == ProcessSignal.sighup) return 1;
    if (signal == ProcessSignal.sigint) return 2;
    if (signal == ProcessSignal.sigusr1) return 10;
    if (signal == ProcessSignal.sigusr2) return 12;
    return 15;
  }

  @override
  void resize(int width, int height) {
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

class PtyCoreUnixWorker implements PtyCoreWorker {
  final int ptm;
  final int pid;
  final Pointer<Int8> buffer;
  final int bufferSize;

  PtyCoreUnixWorker({
    required this.ptm,
    required this.pid,
    required this.buffer,
    required this.bufferSize,
  });

  @override
  Uint8List? read() {
    final readlen = unix.read(ptm, buffer.cast(), bufferSize);
    if (readlen <= 0) {
      return null;
    }
    return Uint8List.fromList(buffer.cast<Uint8>().asTypedList(readlen));
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
    calloc.free(buffer);
  }
}
