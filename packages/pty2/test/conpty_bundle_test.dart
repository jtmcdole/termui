import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:pty2/pty2.dart';
import 'package:pty2/src/impl/conpty_bundle.dart';
import 'package:pty2/src/impl/windows.dart' if (dart.library.html) '';
import 'package:test/test.dart';

void main() {
  group('ConPtyBundle side-by-side resolution', () {
    late Directory tempRoot;

    setUp(() {
      tempRoot = Directory.systemTemp.createTempSync('pty2_conpty_test_');
    });

    tearDown(() {
      if (tempRoot.existsSync()) {
        tempRoot.deleteSync(recursive: true);
      }
    });

    test('requires non-empty conpty.dll and OpenConsole.exe side-by-side', () {
      final dir = Directory(p.join(tempRoot.path, 'pair'))..createSync();
      final dllFile = File(p.join(dir.path, 'conpty.dll'))
        ..writeAsBytesSync([1, 2, 3, 4]);

      // Missing OpenConsole.exe must be rejected so conpty.dll never silently
      // falls back to C:\Windows\System32\conhost.exe.
      expect(ConPtyBundle.hasValidPair(dir), isFalse);
      expect(
        ConPtyBundle.resolveConPtyDllPath(
          environment: {'PTY2_CONPTY_DIR': dir.path},
          resolvedExecutablePath: p.join(tempRoot.path, 'none', 'dart'),
        ),
        isNull,
      );

      // Empty OpenConsole.exe must also be rejected.
      final exeFile = File(p.join(dir.path, 'OpenConsole.exe'))
        ..writeAsBytesSync(const []);
      expect(ConPtyBundle.hasValidPair(dir), isFalse);

      exeFile.writeAsBytesSync([5, 6, 7, 8]);
      expect(ConPtyBundle.hasValidPair(dir), isTrue);
      expect(
        ConPtyBundle.resolveConPtyDllPath(
          environment: {'PTY2_CONPTY_DIR': dir.path},
          resolvedExecutablePath: p.join(tempRoot.path, 'none', 'dart'),
        ),
        dllFile.path,
      );
    });

    test(
      'resolves executable-adjacent directory and PTY2_CONPTY_DIR precedence',
      () {
        final exeDir = Directory(p.join(tempRoot.path, 'bin'))..createSync();
        File(p.join(exeDir.path, 'conpty.dll')).writeAsBytesSync([1, 2]);
        File(p.join(exeDir.path, 'OpenConsole.exe')).writeAsBytesSync([3, 4]);

        expect(
          ConPtyBundle.resolveConPtyDllPath(
            environment: const {},
            resolvedExecutablePath: p.join(exeDir.path, 'termui_cast.exe'),
          ),
          p.join(exeDir.path, 'conpty.dll'),
        );

        final overrideDir = Directory(p.join(tempRoot.path, 'override'))
          ..createSync();
        File(p.join(overrideDir.path, 'conpty.dll')).writeAsBytesSync([9, 10]);
        File(
          p.join(overrideDir.path, 'OpenConsole.exe'),
        ).writeAsBytesSync([11, 12]);

        expect(
          ConPtyBundle.resolveConPtyDllPath(
            environment: {'PTY2_CONPTY_DIR': overrideDir.path},
            resolvedExecutablePath: p.join(exeDir.path, 'termui_cast.exe'),
          ),
          p.join(overrideDir.path, 'conpty.dll'),
        );
      },
    );
  });

  test(
    'Windows OpenConsole passthrough preserves SGR 58;2;R;G;B sequence',
    testOn: 'windows',
    () async {
      final tempDir = Directory.systemTemp.createTempSync('pty2_sgr58_');
      addTearDown(() {
        try {
          if (tempDir.existsSync()) {
            tempDir.deleteSync(recursive: true);
          }
        } on FileSystemException {
          // Ignore transient Windows file lock during teardown.
        }
      });

      final scriptFile = File(p.join(tempDir.path, 'emit_sgr58.dart'))
        ..writeAsStringSync(r'''
import 'dart:io';

void main() {
  stdout.write('START_SGR58\x1b[4;38;2;92;124;232;58;2;92;124;232mJ\x1b[0mEND_SGR58\n');
}
''');

      final pty = PseudoTerminal.start(Platform.executable, [scriptFile.path]);
      addTearDown(() => pty.kill(ProcessSignal.sigkill));

      final fullOutput = await pty.out.join().timeout(
        const Duration(seconds: 15),
      );
      await pty.exitCode.timeout(const Duration(seconds: 5));

      expect(fullOutput, contains('START_SGR58'));
      expect(fullOutput, contains('END_SGR58'));
      if (PtyCoreWindows.isUsingBundledConPty) {
        expect(fullOutput, contains('58;2;92;124;232'));
        expect(fullOutput, isNot(contains('\x1b[92m')));
      }
    },
  );
}
