import 'dart:async';
import 'dart:io';

import 'package:termui_shared_examples/ktty_probe/ktty_local_media_probe.dart';
import 'package:termui_shared_examples/ktty_probe/ktty_local_media_probe_stub.dart'
    as local_media_stub;
import 'package:termui_shared_examples/ktty_probe/ktty_tmux_diagnostics.dart';
import 'package:termui_shared_examples/ktty_probe/ktty_tmux_diagnostics_stub.dart'
    as tmux_stub;
import 'package:test/test.dart';

void main() {
  group('parseTmuxDiagnostics', () {
    test('emits both hints when allow-passthrough is off and RGB missing', () {
      final diag = parseTmuxDiagnostics(
        environment: const {'TMUX': '/tmp/tmux-1000/default,123,0'},
        passthroughOutput: 'allow-passthrough off\n',
        featuresOutput: 'terminal-features[0] xterm*:clipboard:title\n',
        overridesOutput: 'terminal-overrides[0] *256col*:Ms=...\n',
      );

      expect(diag, isNotNull);
      expect(diag!.multiplexer, 'tmux');
      expect(diag.allowPassthrough, 'off');
      expect(diag.hasTrueColor, isFalse);
      expect(diag.hints, [
        'Run: tmux set -gp allow-passthrough on (or all)',
        'Run: tmux set -as terminal-features ",xterm-256color:RGB"',
      ]);
    });

    test('emits zero hints when allow-passthrough is on and RGB present', () {
      final diag = parseTmuxDiagnostics(
        environment: const {'TMUX': '/tmp/tmux-1000/default,123,0'},
        passthroughOutput: 'allow-passthrough on\n',
        featuresOutput: 'terminal-features[0] xterm-256color:RGB\n',
        overridesOutput: '',
      );

      expect(diag, isNotNull);
      expect(diag!.multiplexer, 'tmux');
      expect(diag.allowPassthrough, 'on');
      expect(diag.hasTrueColor, isTrue);
      expect(diag.hints, isEmpty);
    });

    test('accepts allow-passthrough all and Tc in terminal-overrides', () {
      final diag = parseTmuxDiagnostics(
        environment: const {'TMUX': '/tmp/tmux-1000/default,123,0'},
        passthroughOutput: 'allow-passthrough* all\n',
        featuresOutput: null,
        overridesOutput: 'terminal-overrides[0] ",*256col*:Tc"\n',
      );

      expect(diag, isNotNull);
      expect(diag!.allowPassthrough, 'all');
      expect(diag.hasTrueColor, isTrue);
      expect(diag.hints, isEmpty);
    });

    test('treats unknown or null allow-passthrough as needing remediation', () {
      final diag = parseTmuxDiagnostics(
        environment: const {'TMUX': '/tmp/tmux-1000/default,123,0'},
        passthroughOutput: null,
        featuresOutput: 'xterm-256color:RGB',
        overridesOutput: null,
      );

      expect(diag, isNotNull);
      expect(diag!.allowPassthrough, isNull);
      expect(diag.hasTrueColor, isTrue);
      expect(diag.hints, ['Run: tmux set -gp allow-passthrough on (or all)']);
    });

    test('reports GNU screen warning when STY is set without TMUX', () {
      final diag = parseTmuxDiagnostics(
        environment: const {'STY': '4242.pts-0.host'},
        passthroughOutput: null,
        featuresOutput: null,
        overridesOutput: null,
      );

      expect(diag, isNotNull);
      expect(diag!.multiplexer, 'screen');
      expect(diag.allowPassthrough, isNull);
      expect(diag.hasTrueColor, isFalse);
      expect(diag.hints, [
        'GNU screen requires DCS passthrough; Kitty graphics may be stripped.',
      ]);
    });

    test('returns null when neither TMUX nor STY is set', () {
      final diag = parseTmuxDiagnostics(
        environment: const {'TERM': 'xterm-256color'},
        passthroughOutput: 'allow-passthrough on',
        featuresOutput: 'xterm-256color:RGB',
        overridesOutput: null,
      );

      expect(diag, isNull);
    });
  });

  group('detectMultiplexerDiagnostics', () {
    test(
      'returns null without spawning tmux when TMUX and STY are absent',
      () async {
        var calls = 0;
        final diag = await detectMultiplexerDiagnostics(
          environment: const {'TERM': 'xterm-256color'},
          runTmux: (_) async {
            calls++;
            return null;
          },
        );

        expect(diag, isNull);
        expect(calls, 0);
      },
    );

    test(
      'reports screen warning without invoking runTmux when STY is set',
      () async {
        var calls = 0;
        final diag = await detectMultiplexerDiagnostics(
          environment: const {'STY': '1234.pts-1.box'},
          runTmux: (_) async {
            calls++;
            return null;
          },
        );

        expect(diag, isNotNull);
        expect(diag!.multiplexer, 'screen');
        expect(diag.hints, [
          'GNU screen requires DCS passthrough; Kitty graphics may be stripped.',
        ]);
        expect(calls, 0);
      },
    );

    test('queries expected tmux options and parses output', () async {
      final invokedArgs = <List<String>>[];
      final diag = await detectMultiplexerDiagnostics(
        environment: const {'TMUX': '/tmp/tmux-1000/default,99,0'},
        runTmux: (args) async {
          invokedArgs.add(args);
          if (args.contains('allow-passthrough')) {
            return 'allow-passthrough on\n';
          }
          if (args.contains('terminal-features')) {
            return 'terminal-features[0] xterm-256color:RGB\n';
          }
          return '';
        },
      );

      expect(invokedArgs, [
        ['show', '-Ap', 'allow-passthrough'],
        ['show', '-s', 'terminal-features'],
        ['show', '-s', 'terminal-overrides'],
      ]);
      expect(diag, isNotNull);
      expect(diag!.multiplexer, 'tmux');
      expect(diag.allowPassthrough, 'on');
      expect(diag.hasTrueColor, isTrue);
      expect(diag.hints, isEmpty);
    });

    test('handles throwing runTmux safely without throwing', () async {
      final diag = await detectMultiplexerDiagnostics(
        environment: const {'TMUX': '/tmp/tmux-1000/default,99,0'},
        runTmux: (_) async {
          throw const ProcessException('tmux', ['show'], 'No such file', 2);
        },
      );

      expect(diag, isNotNull);
      expect(diag!.multiplexer, 'tmux');
      expect(diag.allowPassthrough, isNull);
      expect(diag.hasTrueColor, isFalse);
      expect(diag.hints, [
        'Run: tmux set -gp allow-passthrough on (or all)',
        'Run: tmux set -as terminal-features ",xterm-256color:RGB"',
      ]);
    });

    test('times out slow runTmux safely without throwing', () async {
      final neverCompletes = Completer<String?>();
      final diag = await detectMultiplexerDiagnostics(
        environment: const {'TMUX': '/tmp/tmux-1000/default,99,0'},
        runTmux: (_) => neverCompletes.future,
      );

      expect(diag, isNotNull);
      expect(diag!.multiplexer, 'tmux');
      expect(diag.allowPassthrough, isNull);
      expect(diag.hasTrueColor, isFalse);
      expect(diag.hints, hasLength(2));
    });

    test(
      'default runner fails safely when tmux is unavailable or detached',
      () async {
        final diag = await detectMultiplexerDiagnostics(
          environment: const {'TMUX': '/nonexistent/ktty-probe-tmux,1,0'},
        );

        expect(diag, isNotNull);
        expect(diag!.multiplexer, 'tmux');
      },
    );

    test('Web stub returns null', () async {
      final diag = await tmux_stub.detectMultiplexerDiagnostics(
        environment: const {'TMUX': '/tmp/tmux-1000/default,99,0'},
      );
      expect(diag, isNull);
    });
  });

  group('createLocalMediaProbeSession', () {
    test('creates 16-byte RGBA fixtures and cleans up on dispose', () {
      final session = createLocalMediaProbeSession();
      addTearDown(session.dispose);

      expect(session.tempFilePath, isNotNull);
      expect(
        session.tempFilePath,
        contains('tty-graphics-protocol-ktty-probe-'),
      );
      expect(session.tempFilePath, endsWith('probe.rgba'));
      expect(session.tempFileStillExists, isTrue);
      expect(File(session.tempFilePath!).lengthSync(), 16);

      // Overlapping sessions in the same process must not collide.
      final second = createLocalMediaProbeSession();
      addTearDown(second.dispose);
      expect(second.tempFilePath, isNot(equals(session.tempFilePath)));

      final expectShm = Platform.isLinux && Directory('/dev/shm').existsSync();
      if (expectShm) {
        expect(
          session.shmObjectName,
          startsWith('/tty-graphics-protocol-ktty-probe-$pid-'),
        );
        expect(second.shmObjectName, isNot(equals(session.shmObjectName)));
        expect(session.shmStillExists, isTrue);
        expect(File('/dev/shm${session.shmObjectName!}').lengthSync(), 16);
      }

      session.dispose();
      expect(session.tempFileStillExists, isFalse);
      expect(File(session.tempFilePath!).existsSync(), isFalse);
      expect(second.tempFileStillExists, isTrue);
      if (expectShm) {
        expect(session.shmStillExists, isFalse);
        expect(File('/dev/shm${session.shmObjectName!}').existsSync(), isFalse);
        expect(second.shmStillExists, isTrue);
      }
      second.dispose();

      // Calling dispose a second time must be a safe no-op.
      expect(session.dispose, returnsNormally);
    });

    test('detects unexpected deletion prior to dispose', () {
      final session = createLocalMediaProbeSession();
      addTearDown(session.dispose);

      expect(session.tempFilePath, isNotNull);
      expect(session.tempFileStillExists, isTrue);
      File(session.tempFilePath!).deleteSync();
      expect(session.tempFileStillExists, isFalse);

      if (session.shmObjectName != null) {
        expect(session.shmStillExists, isTrue);
        File('/dev/shm${session.shmObjectName!}').deleteSync();
        expect(session.shmStillExists, isFalse);
      }

      expect(session.dispose, returnsNormally);
    });

    test('Web stub returns a no-op session', () {
      final session = local_media_stub.createLocalMediaProbeSession();
      expect(session.tempFilePath, isNull);
      expect(session.shmObjectName, isNull);
      expect(session.tempFileStillExists, isFalse);
      expect(session.shmStillExists, isFalse);
      expect(session.dispose, returnsNormally);
    });
  });

  group('Web safety guard', () {
    test('non-_io.dart files under lib/ktty_probe/ never import dart:io', () {
      final dir = Directory('lib/ktty_probe').existsSync()
          ? Directory('lib/ktty_probe')
          : Directory('packages/termui_shared_examples/lib/ktty_probe');
      expect(
        dir.existsSync(),
        isTrue,
        reason: 'Could not locate lib/ktty_probe directory',
      );

      final dartIoImport = RegExp(r'''import\s+['"]dart:io['"]''');
      final checkedFiles = <String>[];
      final violations = <String>[];

      for (final entity in dir.listSync(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        if (entity.path.endsWith('_io.dart')) continue;
        checkedFiles.add(entity.path);
        final source = entity.readAsStringSync();
        if (dartIoImport.hasMatch(source)) {
          violations.add(entity.path);
        }
      }

      expect(
        checkedFiles,
        isNotEmpty,
        reason: 'Expected non-_io.dart files under lib/ktty_probe/',
      );
      expect(
        violations,
        isEmpty,
        reason: 'Found forbidden dart:io import outside *_io.dart: $violations',
      );
    });
  });
}
