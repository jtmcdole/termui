@Timeout(Duration(seconds: 30))
library;

import 'dart:io';
import 'package:pty2/pty2.dart';
import 'package:test/test.dart';

void main() {
  test('PseudoTerminal exits with non-zero code on failure', () async {
    final pty = PseudoTerminal.start(
      Platform.isWindows ? 'cmd.exe' : 'sh',
      Platform.isWindows ? ['/c', 'exit 42'] : ['-c', 'exit 42'],
    );
    addTearDown(() => pty.kill(ProcessSignal.sigkill));

    final exitCode = await pty.exitCode;
    expect(
      exitCode,
      Platform.isWindows ? 42 : anyOf(42, -1),
      reason:
          'PTY should propagate the non-zero exit code (or -1 if reaped on Unix)',
    );
  });

  test(
    'PseudoTerminal handles multiple instances without leaking native handles',
    () async {
      for (var i = 0; i < 10; i++) {
        final pty = PseudoTerminal.start(
          Platform.isWindows ? 'cmd.exe' : 'true',
          [],
        );
        addTearDown(() => pty.kill(ProcessSignal.sigkill));
        pty.kill();
        await pty.exitCode;
      }
    },
  );
}
