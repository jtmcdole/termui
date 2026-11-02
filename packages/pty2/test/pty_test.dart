@Timeout(Duration(seconds: 30))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:pty2/pty2.dart';
import 'package:pty2/src/impl/windows.dart' if (dart.library.html) '';
import 'package:test/test.dart';

PseudoTerminal _startTrackedPty(String executable, List<String> arguments) {
  final pty = PseudoTerminal.start(executable, arguments);
  addTearDown(() {
    pty.kill(ProcessSignal.sigkill);
  });
  return pty;
}

void main() {
  test('Can instantiate and kill PseudoTerminal', () async {
    for (final delayMs in [0, 5, 25]) {
      final pty = _startTrackedPty(_getShell(), []);
      if (delayMs > 0) {
        await Future<void>.delayed(Duration(milliseconds: delayMs));
      }
      pty.kill();
      await pty.exitCode.timeout(const Duration(seconds: 5));
    }
  });

  test('Can read exit code', () async {
    final pty = _startTrackedPty(_getShell(), [
      Platform.isWindows ? '/c' : '-c',
      'exit 3',
    ]);

    expect(
      await pty.exitCode,
      Platform.isWindows ? anyOf(0, 3) : anyOf(0, 3, -1),
    );
  });

  test('echo test', () async {
    final pty = _startTrackedPty(_getShell(), []);
    final output = <String>[];
    final readyCompleter = Completer<void>();
    final doneCompleter = Completer<void>();

    final subscription = pty.out.listen(
      (chunk) {
        output.add(chunk);
        if (!readyCompleter.isCompleted) {
          // Shell banner/prompt has arrived on stdout; shell has initialized
          // and is ready for input.
          readyCompleter.complete();
        }
      },
      onDone: () {
        if (!readyCompleter.isCompleted) readyCompleter.complete();
        if (!doneCompleter.isCompleted) doneCompleter.complete();
      },
    );
    addTearDown(subscription.cancel);

    await readyCompleter.future.timeout(const Duration(seconds: 10));

    if (Platform.isWindows) {
      pty.write('echo hello world\r\n');
      pty.write('exit 0\r\n');
    } else {
      pty.write('echo hello world\n');
      pty.write('exit 0\n');
    }

    await doneCompleter.future.timeout(const Duration(seconds: 10));
    await pty.exitCode.timeout(const Duration(seconds: 5));
    await subscription.cancel();

    expect(output.join(''), contains('hello world'));
  });

  test('Resize terminal', () async {
    final pty = _startTrackedPty(_getShell(), []);
    pty.resize(100, 100);
    pty.kill();
    await pty.exitCode;
  });

  test('Execve failure path', () async {
    final pty = _startTrackedPty('invalid_non_existent_executable', []);
    expect(
      await pty.exitCode,
      Platform.isWindows ? anyOf(0, 1) : anyOf(0, 1, -1, 137),
    );
  });

  if (Platform.isWindows) {
    test('Windows Legacy Pipes Fallback - echo test', () async {
      PtyCoreWindows.forceLegacyForTesting = true;
      addTearDown(() {
        PtyCoreWindows.forceLegacyForTesting = false;
      });
      final pty = _startTrackedPty(_getShell(), []);

      pty.write('echo legacy pipes fallback\r\n');
      pty.write('exit 0\r\n');

      final output = await pty.out.toList();
      final fullOutput = output.join('');

      expect(fullOutput, contains('legacy pipes fallback'));
      expect(await pty.exitCode, 0);
    });

    test('Windows Legacy Pipes Fallback - resize does not crash', () async {
      PtyCoreWindows.forceLegacyForTesting = true;
      addTearDown(() {
        PtyCoreWindows.forceLegacyForTesting = false;
      });
      final pty = _startTrackedPty(_getShell(), []);

      // In legacy mode, resize should gracefully no-op.
      pty.resize(100, 100);
      pty.kill();
      await pty.exitCode;
    });

    test('Windows Race Condition - Read and Kill (Segfault check)', () async {
      // We spawn a process, delay slightly to let the background isolate enter win32.ReadFile,
      // and then call kill() from the main isolate which frees the pointer out from under it.
      for (var i = 0; i < 20; i++) {
        final pty = _startTrackedPty(_getShell(), []);
        await Future<void>.delayed(const Duration(milliseconds: 5));
        pty.kill();
        await pty.exitCode;
      }
    });
  }

  test('Resize sets exact winsize inside PTY child across platforms', () async {
    final pty = _startTrackedPty(Platform.executable, [_getHelperPath()]);
    final output = <String>[];
    final readyCompleter = Completer<void>();
    final doneCompleter = Completer<void>();

    final subscription = pty.out.listen(
      (chunk) {
        output.add(chunk);
        if (chunk.contains('READY') && !readyCompleter.isCompleted) {
          readyCompleter.complete();
        }
      },
      onDone: () {
        if (!readyCompleter.isCompleted) readyCompleter.complete();
        if (!doneCompleter.isCompleted) doneCompleter.complete();
      },
    );
    addTearDown(subscription.cancel);

    await readyCompleter.future.timeout(const Duration(seconds: 10));
    pty.resize(123, 45);

    await doneCompleter.future.timeout(const Duration(seconds: 10));
    await pty.exitCode.timeout(const Duration(seconds: 5));
    await subscription.cancel();

    expect(output.join(''), contains('SIZE:123x45'));
  });

  test(
    'Non-shell executable can be started without -l flag injected',
    () async {
      final pty = _startTrackedPty(Platform.executable, ['--version']);
      final output = await pty.out.join('');
      expect(output.trim(), contains('version'));
    },
  );

  test(
    'PseudoTerminal.start emits zero print lines to parent stdout',
    () async {
      final printedLines = <String>[];
      await runZoned(
        () async {
          final pty = _startTrackedPty(_getShell(), []);
          pty.kill();
          await pty.exitCode.timeout(const Duration(seconds: 5));
        },
        zoneSpecification: ZoneSpecification(
          print: (self, parent, zone, line) {
            printedLines.add(line);
          },
        ),
      );
      expect(printedLines, isEmpty);
    },
  );

  test('Resize after natural child exit returns normally', () async {
    final pty = _startTrackedPty(_getShell(), [
      Platform.isWindows ? '/c' : '-c',
      'exit 0',
    ]);
    await pty.exitCode.timeout(const Duration(seconds: 5));
    expect(() => pty.resize(50, 120), returnsNormally);
    await pty.out.drain<void>().timeout(const Duration(seconds: 5));
    expect(() => pty.resize(50, 120), returnsNormally);
  });

  test(
    'PseudoTerminal.start preserves tricky arguments across platforms',
    () async {
      final tempDir = Directory.systemTemp.createTempSync('pty2_arg_quote_');
      addTearDown(() {
        try {
          if (tempDir.existsSync()) {
            tempDir.deleteSync(recursive: true);
          }
        } on FileSystemException {
          // Ignore transient Windows file lock during teardown.
        }
      });

      final scriptFile = File('${tempDir.path}/print_args.dart')
        ..writeAsStringSync('''
import 'dart:convert';

void main(List<String> args) {
  print('ARGS_START\${jsonEncode(args)}ARGS_END');
}
''');

      const expectedArgs = ['a"b', r'C:\dir with space\', 'x\ty', ''];
      final pty = _startTrackedPty(Platform.executable, [
        scriptFile.path,
        ...expectedArgs,
      ]);

      final fullOutput = await pty.out.join().timeout(
        const Duration(seconds: 15),
      );
      await pty.exitCode.timeout(const Duration(seconds: 5));

      final match = RegExp(
        r'ARGS_START(.*?)ARGS_END',
        dotAll: true,
      ).firstMatch(fullOutput);
      expect(match, isNotNull, reason: 'Unexpected PTY output: $fullOutput');

      final rawJson = match!
          .group(1)!
          .replaceAll('\r', '')
          .replaceAll('\n', '');
      final Object? decoded = jsonDecode(rawJson);
      expect(decoded, equals(expectedArgs));
    },
  );

  group('PtyCoreWindows.buildWindowsCommandLine', () {
    test('leaves simple executable and arguments unquoted', () {
      expect(
        PtyCoreWindows.buildWindowsCommandLine('cmd.exe', [
          '/c',
          r'C:\plain\path\',
        ]),
        r'cmd.exe /c C:\plain\path\',
      );
    });

    test('quotes empty strings and arguments with spaces or tabs', () {
      expect(
        PtyCoreWindows.buildWindowsCommandLine(
          r'C:\Program Files\Dart\dart.exe',
          ['', 'hello world', 'x\ty'],
        ),
        '"C:\\Program Files\\Dart\\dart.exe" "" "hello world" "x\ty"',
      );
    });

    test('escapes embedded quotes and preceding backslashes', () {
      expect(
        PtyCoreWindows.buildWindowsCommandLine('app.exe', [
          'a"b',
          r'a\"b',
          r'a\\"b',
        ]),
        r'app.exe "a\"b" "a\\\"b" "a\\\\\"b"',
      );
    });

    test('doubles trailing backslashes only when quoting is required', () {
      expect(
        PtyCoreWindows.buildWindowsCommandLine('app.exe', [
          r'C:\dir with space\',
          r'C:\dir with space\\',
          r'C:\no_space\',
        ]),
        r'app.exe "C:\dir with space\\" "C:\dir with space\\\\" C:\no_space\',
      );
    });
  });
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
