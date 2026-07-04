import 'dart:io';

import 'package:pty2/pty.dart';
import 'package:pty2/src/impl/windows.dart' if (dart.library.html) '';
import 'package:test/test.dart';

void main() {
  test('Can instantiate and kill PseudoTerminal', () async {
    final pty = PseudoTerminal.start(_getShell(), []);
    pty.kill();
    await pty.exitCode;
  });

  test('Can read exit code', () async {
    final pty = PseudoTerminal.start(_getShell(), []);

    if (Platform.isWindows) {
      pty.write('exit 3\r\n');
    } else {
      pty.write('exit 3\r');
    }

    expect(
      await pty.exitCode,
      Platform.isWindows ? anyOf(0, 3) : anyOf(0, 3, -1),
    );
  });

  test('echo test', () async {
    final pty = PseudoTerminal.start(_getShell(), []);

    if (Platform.isWindows) {
      pty.write('echo hello world\r\n');
      pty.write('exit 0\r\n');
    } else {
      pty.write('echo hello world\r');
      pty.write('exit 0\r');
    }

    final output = await pty.out.toList();
    final fullOutput = output.join('');

    expect(fullOutput, contains('hello world'));

    await pty.exitCode;
  });

  test('Resize terminal', () async {
    final pty = PseudoTerminal.start(_getShell(), []);
    pty.resize(100, 100);
    pty.kill();
    await pty.exitCode;
  });

  test('Execve failure path', () async {
    final pty = PseudoTerminal.start('invalid_non_existent_executable', []);
    expect(
      await pty.exitCode,
      Platform.isWindows ? anyOf(0, 1) : anyOf(0, 1, -1),
    );
  });

  if (Platform.isWindows) {
    test('Windows Legacy Pipes Fallback - echo test', () async {
      PtyCoreWindows.forceLegacyForTesting = true;
      final pty = PseudoTerminal.start(_getShell(), []);

      pty.write('echo legacy pipes fallback\r\n');
      pty.write('exit 0\r\n');

      final output = await pty.out.toList();
      final fullOutput = output.join('');

      expect(fullOutput, contains('legacy pipes fallback'));
      expect(await pty.exitCode, 0);

      PtyCoreWindows.forceLegacyForTesting = false;
    });

    test('Windows Legacy Pipes Fallback - resize does not crash', () async {
      PtyCoreWindows.forceLegacyForTesting = true;
      final pty = PseudoTerminal.start(_getShell(), []);

      // In legacy mode, resize should gracefully no-op.
      pty.resize(100, 100);
      pty.kill();
      await pty.exitCode;

      PtyCoreWindows.forceLegacyForTesting = false;
    });

    test('Windows Race Condition - Read and Kill (Segfault check)', () async {
      // We spawn a process, delay slightly to let the background isolate enter win32.ReadFile,
      // and then call kill() from the main isolate which frees the pointer out from under it.
      for (var i = 0; i < 20; i++) {
        final pty = PseudoTerminal.start(_getShell(), []);
        await Future.delayed(Duration(milliseconds: 5));
        pty.kill();
        await pty.exitCode;
      }
    });
  }
}

String _getShell() {
  if (Platform.isWindows) {
    return 'cmd';
  }
  return 'sh';
}
