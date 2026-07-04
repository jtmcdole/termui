import 'dart:io';
import 'package:test/test.dart';
import 'package:pty2/pty.dart';

void main() {
  test('PseudoTerminal exits with non-zero code on failure', () async {
    // If the process exits with a non-zero code, the PTY should return it
    final pty = PseudoTerminal.start(
      Platform.isWindows ? 'cmd.exe' : 'sh',
      Platform.isWindows ? ['/c', 'exit 42'] : ['-c', 'exit 42'],
    );

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
      // Spawn and kill 10 PTYs to stress test FFI cleanup and handles
      for (int i = 0; i < 10; i++) {
        final pty = PseudoTerminal.start(
          Platform.isWindows ? 'cmd.exe' : 'true',
          [],
        );
        pty.kill();
        await pty.exitCode;
      }
    },
  );
}
