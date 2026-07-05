import 'dart:io';
import 'dart:isolate';
import 'package:pty2/pty2.dart';
import 'package:test/test.dart';

void heavyAllocator(SendPort sendPort) {
  while (true) {
    List.generate(10000, (i) => '${i}alloc');
  }
}

void main() {
  test(
    'PseudoTerminal handles concurrent GC allocations without deadlocking on fork',
    () async {
      final isolates = <Isolate>[];
      for (var i = 0; i < 2; i++) {
        final port = ReceivePort();
        isolates.add(await Isolate.spawn(heavyAllocator, port.sendPort));
      }

      try {
        for (var i = 0; i < 1; i++) {
          print('starting $i');
          final exec = Platform.isWindows ? 'cmd.exe' : 'sh';
          final args = Platform.isWindows ? ['/c', 'exit 0'] : ['-c', 'exit 0'];
          final pty = PseudoTerminal.start(exec, args);
          print('started $i');
          final code = await pty.exitCode.timeout(const Duration(seconds: 10));
          print('exited $i');
          expect(code, anyOf(0, -1));
        }
      } finally {
        for (var isolate in isolates) {
          isolate.kill(priority: Isolate.immediate);
        }
      }
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );
}
