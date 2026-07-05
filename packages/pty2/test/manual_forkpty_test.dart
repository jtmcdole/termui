import 'dart:ffi';
import 'package:ffi/ffi.dart';
import 'dart:isolate';
import 'package:test/test.dart';

typedef _c_openpty = Int32 Function(Pointer<Int32>, Pointer<Int32>, Pointer<Int8>, Pointer<Void>, Pointer<Void>);
typedef _dart_openpty = int Function(Pointer<Int32>, Pointer<Int32>, Pointer<Int8>, Pointer<Void>, Pointer<Void>);

typedef _c_fork = Int32 Function();
typedef _dart_fork = int Function();

@Native<Void Function(Int32)>(symbol: '_exit', isLeaf: true)
external void _exit(int status);

@Native<Int32 Function()>(symbol: 'setsid', isLeaf: true)
external int setsid();

@Native<Int32 Function(Int32, Uint64, Pointer<Void>)>(symbol: 'ioctl', isLeaf: true)
external int ioctl(int fd, int request, Pointer<Void> argp);

@Native<Int32 Function(Int32, Int32)>(symbol: 'dup2', isLeaf: true)
external int dup2(int oldfd, int newfd);

@Native<Int32 Function(Int32)>(symbol: 'close', isLeaf: true)
external int close_fd(int fd);

void heavyAllocator(SendPort sendPort) {
  while (true) {
    List.generate(10000, (i) => i.toString() + "alloc");
  }
}

void main() {
  test('Manual openpty and fork', () async {
    final isolates = <Isolate>[];
    for (var i = 0; i < 2; i++) {
      final port = ReceivePort();
      isolates.add(await Isolate.spawn(heavyAllocator, port.sendPort));
    }

    final lib = DynamicLibrary.process();
    final utilsLib = DynamicLibrary.open('libutil.so.1'); // Ubuntu
    final openpty = utilsLib.lookupFunction<_c_openpty, _dart_openpty>('openpty');
    final fork_func = lib.lookupFunction<_c_fork, _dart_fork>('fork');

    final amaster = calloc<Int32>();
    final aslave = calloc<Int32>();

    try {
      for (var i = 0; i < 1000; i++) {
        if (openpty(amaster, aslave, nullptr, nullptr, nullptr) != 0) {
          throw Exception("openpty failed");
        }

        final pid = fork_func();
        if (pid == 0) {
          setsid();
          // TIOCSCTTY is 0x540E on Linux
          ioctl(aslave.value, 0x540E, nullptr);
          dup2(aslave.value, 0);
          dup2(aslave.value, 1);
          dup2(aslave.value, 2);
          close_fd(amaster.value);
          close_fd(aslave.value);
          _exit(0);
        } else {
          close_fd(aslave.value);
          close_fd(amaster.value);
          await Future.delayed(const Duration(milliseconds: 1));
        }
      }
    } finally {
      calloc.free(amaster);
      calloc.free(aslave);
      for (var isolate in isolates) {
        isolate.kill(priority: Isolate.immediate);
      }
    }
  }, timeout: const Timeout(Duration(seconds: 30)));
}
