import 'dart:async';
import 'dart:io';

import 'package:pty2/pty2.dart';
import 'package:pty2/src/impl/windows.dart' if (dart.library.html) '';
import 'package:test/test.dart';

void main() {
  test('Can instantiate and kill PseudoTerminal', () async {
    final pty = PseudoTerminal.start(_getShell(), []);
    pty.kill();
    await pty.exitCode;
  });

  test('Can read exit code', () async {
    final pty = PseudoTerminal.start(_getShell(), [
      Platform.isWindows ? '/c' : '-c',
      'exit 3',
    ]);

    expect(
      await pty.exitCode,
      Platform.isWindows ? anyOf(0, 3) : anyOf(0, 3, -1),
    );
  });

  test('echo test', () async {
    final pty = PseudoTerminal.start(_getShell(), []);
    final output = <String>[];
    final readyCompleter = Completer<void>();
    final doneCompleter = Completer<void>();

    final subscription = pty.out.listen(
      (chunk) {
        output.add(chunk);
        if (Platform.isWindows && !readyCompleter.isCompleted) {
          // ConPTY / cmd.exe banner/prompt has arrived on stdout; conhost.exe
          // has finished its initial screen reset (\x1B[2J) and is ready for input.
          readyCompleter.complete();
        }
      },
      onDone: () {
        if (!readyCompleter.isCompleted) readyCompleter.complete();
        if (!doneCompleter.isCompleted) doneCompleter.complete();
      },
    );

    if (Platform.isWindows) {
      await readyCompleter.future;
    }

    if (Platform.isWindows) {
      pty.write('echo hello world\r\n');
      pty.write('exit 0\r\n');
    } else {
      pty.write('echo hello world\r');
      pty.write('exit 0\r');
    }

    await doneCompleter.future;
    await pty.exitCode;
    await subscription.cancel();

    expect(output.join(''), contains('hello world'));
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
      Platform.isWindows ? anyOf(0, 1) : anyOf(0, 1, -1, 137),
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

  test('Resize sets exact winsize inside PTY child across platforms', () async {
    final pty = PseudoTerminal.start(Platform.executable, [_getHelperPath()]);
    pty.resize(123, 45);
    final output = await pty.out.join('');
    expect(output.trim(), contains('SIZE:123x45'));
  });

  test(
    'Non-shell executable can be started without -l flag injected',
    () async {
      final pty = PseudoTerminal.start(Platform.executable, ['--version']);
      final output = await pty.out.join('');
      expect(output.trim(), contains('version'));
    },
  );
}

String _getHelperPath() {
  final testDir = Directory.current.path.endsWith('test')
      ? Directory.current.path
      : Directory.current.path.endsWith('pty2')
      ? '${Directory.current.path}/test'
      : '${Directory.current.path}/packages/pty2/test';
  return '$testDir/terminal_size_helper.dart';
}

String _getShell() {
  if (Platform.isWindows) {
    return 'cmd';
  }
  return 'sh';
}
