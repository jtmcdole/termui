@Timeout(Duration(seconds: 30))
library;

import 'dart:io';

import 'package:pty2/pty2.dart';
import 'package:test/test.dart';

void main() {
  test(
    'Spawning 5 short-lived processes does not leak file descriptors on Linux',
    () async {
      if (!Platform.isLinux) return;

      int countPtmxFds() {
        var count = 0;
        for (final entry in Directory(
          '/proc/self/fd',
        ).listSync(followLinks: false)) {
          try {
            if (Link(entry.path).targetSync().contains('ptmx')) {
              count++;
            }
          } on FileSystemException {
            // FD closed while listing.
          }
        }
        return count;
      }

      // Warm up one process so one-time isolate/FFI resources are initialized.
      final warmup = PseudoTerminal.start('/bin/sh', ['-c', 'exit 0']);
      addTearDown(() => warmup.kill(ProcessSignal.sigkill));
      await warmup.exitCode;
      await warmup.out.drain<void>();
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final baselinePtmx = countPtmxFds();

      for (var i = 0; i < 5; i++) {
        final pty = PseudoTerminal.start('/bin/sh', ['-c', 'exit 0']);
        addTearDown(() => pty.kill(ProcessSignal.sigkill));
        await pty.exitCode;
        await pty.out.drain<void>();
      }

      var afterPtmx = countPtmxFds();
      for (
        var attempt = 0;
        attempt < 20 && afterPtmx > baselinePtmx;
        attempt++
      ) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        afterPtmx = countPtmxFds();
      }

      expect(
        afterPtmx,
        lessThanOrEqualTo(baselinePtmx),
        reason: 'Natural child exit must close master PTY fd without leaking',
      );
    },
  );
}
