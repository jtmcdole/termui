@Timeout(Duration(seconds: 45))
library;

import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'package:pty2/pty2.dart';
import 'package:test/test.dart';

void _heavyAllocator(void _) {
  while (true) {
    List.generate(10000, (i) => '${i}alloc');
  }
}

void _cleanupResources(Set<PseudoTerminal> activePtys, List<Isolate> isolates) {
  for (final pty in activePtys) {
    pty.kill(ProcessSignal.sigkill);
  }
  activePtys.clear();
  for (final isolate in isolates) {
    isolate.kill(priority: Isolate.immediate);
  }
  isolates.clear();
}

Future<void> _runOnePty(
  String exec,
  List<String> args,
  Set<PseudoTerminal> activePtys,
) async {
  final pty = PseudoTerminal.start(exec, args);
  activePtys.add(pty);
  final drainFuture = pty.out.drain<void>();
  try {
    final code = await pty.exitCode.timeout(const Duration(seconds: 10));
    expect(code, anyOf(0, -1));
    await drainFuture.timeout(const Duration(seconds: 5));
  } catch (_) {
    pty.kill(ProcessSignal.sigkill);
    await pty.exitCode.timeout(const Duration(seconds: 2), onTimeout: () => -1);
    await drainFuture.timeout(const Duration(seconds: 2), onTimeout: () {});
    rethrow;
  } finally {
    activePtys.remove(pty);
  }
}

Future<void> _runStressBatches(Set<PseudoTerminal> activePtys) async {
  final batches = Platform.isWindows ? 3 : 5;
  final batchSize = Platform.isWindows ? 1 : 4;
  final exec = Platform.isWindows ? 'cmd.exe' : 'sh';
  final args = Platform.isWindows ? ['/c', 'exit 0'] : ['-c', 'exit 0'];

  for (var b = 0; b < batches; b++) {
    await Future.wait([
      for (var i = 0; i < batchSize; i++) _runOnePty(exec, args, activePtys),
    ]);
  }
}

void main() {
  test(
    'PseudoTerminal handles concurrent GC allocations without deadlocking on fork',
    () async {
      final activePtys = <PseudoTerminal>{};
      final isolates = <Isolate>[];

      addTearDown(() => _cleanupResources(activePtys, isolates));

      for (var i = 0; i < 2; i++) {
        isolates.add(await Isolate.spawn(_heavyAllocator, null));
      }

      try {
        await _runStressBatches(activePtys);
      } finally {
        _cleanupResources(activePtys, isolates);
      }
    },
  );
}
