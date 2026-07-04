import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:pty2/src/pty_core.dart';
import 'package:pty2/src/pty_error.dart';
import 'package:pty2/src/util/unix_const.dart';
import 'package:pty2/src/util/unix_ffi.dart';

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

    final pPtm = calloc<Int32>();
    pPtm.value = -1;

    final sz = calloc<winsize>();
    sz.ref.ws_col = 80;
    sz.ref.ws_row = 20;

    final pid = unix.forkpty(pPtm, nullptr, nullptr, sz);
    calloc.free(sz);

    var ptm = pPtm.value;
    calloc.free(pPtm);

    if (pid < 0) {
      throw PtyException('fork failed.');
    } else if (pid == 0) {
      // Close all file descriptors except stdin, stdout, stderr (0, 1, 2)
      // This prevents slave PTYs from leaking into concurrent child processes
      // across different isolates when forkpty races.
      if (Platform.isLinux && unix.close_range != null) {
        final ret = unix.close_range!(3, 4294967295, 0); // ~0U is 4294967295
        if (ret == -1) {
          for (var fd = 3; fd < 1024; fd++) {
            unix.close(fd);
          }
        }
      } else if (unix.closefrom != null) {
        unix.closefrom!(3);
      } else {
        for (var fd = 3; fd < 1024; fd++) {
          unix.close(fd);
        }
      }

      // set working directory
      if (workingDirectory != null) {
        unix.chdir(workingDirectory.toNativeUtf8());
      }

      // build argv
      final argv = calloc<Pointer<Utf8>>(arguments.length + 2);
      (argv + 0).value = executable.toNativeUtf8();
      (argv + arguments.length + 1).value = nullptr;
      for (var i = 0; i < arguments.length; i++) {
        (argv + i + 1).value = arguments[i].toNativeUtf8();
      }

      //build env
      final env = calloc<Pointer<Utf8>>(effectiveEnv.length + 1);
      (env + effectiveEnv.length).value = nullptr;
      var cnt = 0;
      for (var entry in effectiveEnv.entries) {
        final envVal = '${entry.key}=${entry.value}';
        (env + cnt).value = envVal.toNativeUtf8();
        cnt++;
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

      unix.execve(resolvedExecutable.toNativeUtf8(), argv, env);
      unix.cExit(1);
    } else {
      unix.setsid();

      if (raw && unix.cfmakeraw != null) {
        final termp = calloc<termios>();
        if (unix.tcgetattr(ptm, termp) != -1) {
          unix.cfmakeraw!(termp);
          unix.tcsetattr(ptm, consts.TCSANOW, termp);
        }
        calloc.free(termp);
      }

      return PtyCoreUnix._(pid, ptm);
    }

    throw PtyException('unreachable');
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
